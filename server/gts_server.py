#!/usr/bin/env python3
"""Gen1Online+ server: GTS, Wonder Trade, presence, chat, PVP relay, parties.

A small server for playing Gen1Online+ with friends.  One file, Python 3.8+,
standard library only: nothing to install.

    python3 server/gts_server.py                 # 0.0.0.0:7779, data next to this file
    python3 server/gts_server.py --port 8000 --data /srv/gen1online.json

Options can also come from the environment: PORT, GTS_DB_PATH,
GTS_GENERATION, GTS_CONFIG and GTS_MOD_VERSION (the version this server
speaks; clients with the same major.minor are accepted).

Game modes come from server/server_config.txt (or --config): a hardcore
Nuzlocke and a co-op randomizer, both off by default and played on Gen 1
and FireRed/LeafGreen worlds.  The server owns the run (its number and its seed) and the team's
shared key items and badges; the clients do the rest.  See that file.

A server, or more exactly its data file, is one world for one generation:
Gen 1 (Red/Blue/Yellow), Gen 2 (Crystal) or Gen 3 (FireRed/LeafGreen).
`--gen 1`, `--gen 2` or `--gen 3` picks it; without it the first game to
connect decides.  Games of another generation are turned away with
WRONG_GENERATION.  To host several, run one server per generation with
different --port and --data.

The wire protocol is the one the mod's client (main.lua) speaks, written up
in CLAUDE.md: plain HTTP, `POST /gts` with a JSON body dispatched on
`action`, a handful of GETs, and every answer is JSON sent with HTTP 200,
errors included, as `{"success": false, "error": "CODE"}`.

Accounts, GTS listings and claims, the trade history, chat, the Wonder Trade
pool and its claims are saved to a JSON file (written atomically).  Who is
online, challenges, battle rooms and parties live in memory only.

There is no analytics, rate limiting, IP logging or anti-cheat: run it for
people you trust (on your LAN, over Tailscale, or behind a port forward you
only share with friends).
"""

import argparse
import copy
import json
import os
import random
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_VERSION = "0.5.1"
DEFAULT_PORT = 7779
DEFAULT_DATA = os.path.join(SCRIPT_DIR, "gts_data.json")
DEFAULT_CONFIG = os.path.join(SCRIPT_DIR, "server_config.txt")

PRESENCE_TTL = 30            # a player is dropped after this long without a sync
SESSION_LOCK = 10            # another session is "live" if it synced this recently
CHALLENGE_TTL = 15
INVITE_TTL = 30
ROOM_IDLE_TTL = 30 * 60      # battle rooms nobody touched for this long are dropped
PARTY_IDLE_TTL = 60 * 60     # parties whose members all left this long ago are dropped
LISTING_TTL = 30 * 86400     # an expired listing's mon goes back to its owner's claims
CLAIM_TTL = 60 * 86400
MAX_PLAYERS_PER_MAP = 16
MAX_LISTINGS_PER_TRAINER = 10   # the client allows 10
MAX_WANTED = 3
MAX_PARTY = 4
WONDER_THRESHOLD = 5
HISTORY_KEEP = 50
CHAT_KEEP = 100
CHAT_HISTORY_SENT = 50
CHAT_MAX_LEN = 200           # the client's limit
NAME_MAX_LEN = 16
MAX_BODY = 2 * 1024 * 1024
MAX_INBOX = 500

# The client's addMmoXp amounts.  sync_xp carries the client's own delta in
# `xp`; this table is only the fallback for a client that leaves it out.
XP_TABLE = {
    "catch": 50,
    "wild_battle": 15,
    "trainer_battle": 40,
    "pvp_win": 100,
    "pvp_loss": 25,
    "breeding": 50,
    "gts_trade": 100,
    "gts_deposit": 25,
    "gts_claim": 50,
    "wonder_trade": 75,
    "party_share": 50,
}
XP_DEFAULT = 10

GENERATION_NAMES = {1: "Gen 1 (Red/Blue/Yellow)", 2: "Gen 2 (Crystal)",
                    3: "Gen 3 (FireRed/LeafGreen)"}
# Recovery tokens are typed on the game's own keyboard: Crystal's box keyboard
# and FireRed/LeafGreen's naming screen have digits, Gen 1's has letters only.
TOKEN_LENGTH = 8
TOKEN_ALPHABETS = {1: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", 2: "0123456789ABCDEF",
                   3: "0123456789ABCDEF"}
# the client sends GameVersion's displayName ("Pokemon Red"); the Gen 3 names
# go first because "firered" contains "red"
GAME_GENERATIONS = (("firered", 3), ("leafgreen", 3), ("emerald", 3), ("ruby", 3),
                    ("sapphire", 3), ("crystal", 2), ("gold", 2), ("silver", 2),
                    ("red", 1), ("blue", 1), ("yellow", 1))
XP_MAX_DELTA = 500
MAX_LEVEL = 100

CHALLENGE_TYPES = ("PVP", "TRADE", "ACCEPT_PVP", "ACCEPT_TRADE", "DECLINE")

# Presence fields a sync_pos may carry; each is echoed to the other players.
# FireRed/LeafGreen add the avatar's state (bike, surf...), gender and elevation.
PRESENCE_FIELDS = ("name", "spriteId", "title", "level", "map", "x", "y", "px",
                   "py", "fx", "fy", "facing", "moving", "species", "state",
                   "gender", "elevation")

# Game modes (server_config.txt).  Booleans read on/off, yes/no, true/false, 1/0;
# "auto" for shared_key_items means "on when the randomizer is".
RULE_DEFAULTS = {
    "nuzlocke": "off",            # off | hardcore
    "randomizer": False,
    "randomize_encounters": True,
    "randomize_items": True,
    "randomize_badges": True,
    "randomize_starters": True,
    "shared_key_items": "auto",
    "multiworld": False,
    "players": 2,
    "seed": None,
}
NUZLOCKE_MODES = ("off", "hardcore")
# The game modes' rules a client plays (it sends modesVersion with every
# POST).  While a mode is on, a Gen 1 or FireRed/LeafGreen client below this
# is turned away with VERSION_MISMATCH, so nobody plays an old copy of the
# rules (2: the strict first encounter, no dupes clause).
MODES_VERSION = 2
MODES_GENERATIONS = (1, 3)
MAX_WORLDS = 8
SEED_MAX = 2147483646           # the client's Park-Miller generator takes 1..2^31-2
TEAM_ITEM_MAX = 64              # distinct shared items the team can hold
LOCATION_MAX_LEN = 64

RANK_TITLES = ((100, "POKéMON LEGEND"), (90, "GRAND MASTER"), (80, "CHAMPION"),
               (70, "ELITE FOUR"), (60, "VETERAN"), (50, "MASTER"),
               (40, "ACE TRAINER"), (30, "EXPERT"), (20, "TRAINER"),
               (10, "ROOKIE"))


class ApiError(Exception):
    """An error answer: {"success": false, "error": code}."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


# --------------------------------------------------------------------------
# small helpers

def series(version):
    """The major.minor of a version string, or None."""
    m = re.match(r"\s*v?(\d+)\.(\d+)", str(version or ""))
    return (int(m.group(1)), int(m.group(2))) if m else None


def xp_for_level(level):
    """The client's curve (calculateXpForLevel)."""
    if level <= 1:
        return 0
    return int(50 * ((level - 1) ** 1.8))


def level_for_xp(xp):
    for level in range(MAX_LEVEL, 0, -1):
        if xp >= xp_for_level(level):
            return level
    return 1


def rank_title(level):
    for floor, title in RANK_TITLES:
        if level >= floor:
            return title
    return "NOVICE"


def tid_of(value):
    """Trainer ids travel as numbers or strings; they are keyed as strings."""
    if value is None or isinstance(value, bool):
        return ""
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value).strip()


def to_int(value, default=0):
    if isinstance(value, bool):
        return int(value)
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return default


def clean_text(value, limit):
    if value is None:
        return ""
    return str(value).strip()[:limit]


def fold(name):
    return str(name or "").strip().casefold()


def mon_name(mon):
    if isinstance(mon, dict):
        # FireRed/LeafGreen mons carry their species as a number, and its name
        # beside it for messages like this one
        return str(mon.get("nickname") or mon.get("speciesName") or mon.get("species")
                   or "POKéMON")
    return "POKéMON"


def valid_mon(mon):
    return isinstance(mon, dict) and bool(mon.get("species"))


def parse_bool(value):
    text = str(value).strip().lower()
    if text in ("on", "yes", "true", "1"):
        return True
    if text in ("off", "no", "false", "0"):
        return False
    raise ValueError("expected on or off, got %r" % value)


def parse_rules(text):
    """server_config.txt's key = value lines as a rules dict (see RULE_DEFAULTS).
    Raises ValueError on an unknown key or a bad value, naming the line."""
    rules = dict(RULE_DEFAULTS)
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise ValueError("line %d: expected key = value" % number)
        key, value = (part.strip() for part in line.split("=", 1))
        key = key.lower()
        try:
            if key not in RULE_DEFAULTS:
                raise ValueError("unknown setting %r" % key)
            if key == "nuzlocke":
                value = value.lower() or "off"
                if value not in NUZLOCKE_MODES:
                    raise ValueError("nuzlocke is off or hardcore, not %r" % value)
                rules[key] = value
            elif key == "seed":
                if value:
                    seed = int(value)
                    if not 1 <= seed <= SEED_MAX:
                        raise ValueError("seed must be 1..%d" % SEED_MAX)
                    rules[key] = seed
            elif key == "shared_key_items" and value.lower() == "auto":
                rules[key] = "auto"
            elif key == "players":
                players = int(value)
                if not 2 <= players <= MAX_WORLDS:
                    raise ValueError("players must be 2..%d" % MAX_WORLDS)
                rules[key] = players
            else:
                rules[key] = parse_bool(value)
        except ValueError as err:
            raise ValueError("line %d: %s" % (number, err))
    return rules


def load_rules(path):
    """The rules in `path`, or the defaults (everything off) when it is missing."""
    if not path or not os.path.exists(path):
        return dict(RULE_DEFAULTS)
    with open(path, "r", encoding="utf-8") as f:
        return parse_rules(f.read())


def rules_view(rules):
    """The rules as clients see them: modes that are off read false."""
    rando = bool(rules.get("randomizer"))
    shared = rules.get("shared_key_items")
    if shared == "auto":
        shared = rando
    view = {
        "nuzlocke": rules.get("nuzlocke") or "off",
        "randomizer": rando,
        "encounters": rando and bool(rules.get("randomize_encounters")),
        "items": rando and bool(rules.get("randomize_items")),
        "badges": rando and bool(rules.get("randomize_badges")),
        "starters": rando and bool(rules.get("randomize_starters")),
        "sharedKeyItems": bool(shared),
    }
    # the multiworld splits the shuffled items across worlds: it needs the
    # randomizer and the team's shared finds
    multi = rando and bool(rules.get("multiworld")) and (view["items"] or view["badges"])
    view["multiworld"] = bool(multi)
    view["players"] = int(rules.get("players") or 2) if multi else 1
    if multi:
        view["sharedKeyItems"] = True
    view["active"] = (view["nuzlocke"] != "off" or view["randomizer"]
                      or view["sharedKeyItems"])
    return view


def generation_of(explicit, game_version):
    """1, 2 or 3 for a client, or None when it does not say (a script, a test)."""
    gen = to_int(explicit, 0)
    if gen in (1, 2, 3):
        return gen
    name = str(game_version or "").lower().replace(" ", "")
    for key, value in GAME_GENERATIONS:
        if key in name:
            return value
    return None


def empty_data():
    return {
        "schema": 1,
        "accounts": {},        # trainerId -> account
        "listings": {},        # "GTS_<n>" -> listing
        "claims": {},          # trainerId -> [claim]
        "history": [],         # newest first
        "chat": [],            # oldest first
        "wonderPool": [],      # [{trainerId, trainerName, offeredMon, timestamp}]
        "wonderClaims": {},    # trainerId -> {mon, fromName, fromId, sentMon, timestamp}
        "nextChatId": 1,
        "nextListingId": 1001,
        "nextClaimId": 1,
        "generation": None,    # 1, 2 or 3 once set: this world's generation
        "run": {},             # {id, seed, started}: the game modes' current run
        "team": {},            # {items: {ITEM: {by, name, time}}, rev}: shared key items
    }


# --------------------------------------------------------------------------
# the server state and every action

class GtsStore:
    """All server state behind one lock.  HTTP-agnostic, so tests can drive it."""

    def __init__(self, path, version=DEFAULT_VERSION, clock=time.time, rng=None,
                 generation=None, rules=None):
        self.path = path
        self.version = version
        self.clock = clock
        self.rng = rng or random.SystemRandom()
        self.lock = threading.RLock()
        self.announce = lambda text: print(text, flush=True)
        self.rules = dict(RULE_DEFAULTS)
        self.rules.update(rules or {})
        self.data = self._load()
        if not self.data["run"].get("id"):
            self._begin_run(1)
        if generation is not None:
            if generation not in GENERATION_NAMES:
                raise ValueError("generation must be 1, 2 or 3")
            current = self.data["generation"]
            if current is None:
                self.data["generation"] = generation
                self.save()
            elif current != generation:
                raise ValueError(
                    "%s is a %s world, not %s. Use a different --data file for a %s server."
                    % (self.path, GENERATION_NAMES[current], GENERATION_NAMES[generation],
                       GENERATION_NAMES[generation]))
        # memory only
        self.presence = {}      # tid -> {"entry": {...}, "session": str, "seen": t}
        self.last_seen = {}     # tid -> t, for parties
        self.challenges = {}    # tid -> {"challenge": {...}, "expires": t}
        self.rooms = {}         # roomId -> {"inboxes": {tid: [msg]}, "touched": t}
        self.parties = {}       # partyId -> {"leaderId": tid, "members": {tid: {...}}}
        self.party_of = {}      # tid -> partyId
        self.invites = {}       # tid -> {"fromId", "fromName", "partyId", "expires"}
        self.next_party_id = 1
        self._next_sweep = 0
        self._next_slow_sweep = 0

    # ---- persistence ------------------------------------------------------

    def _load(self):
        data = empty_data()
        if not os.path.exists(self.path):
            return data
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            if not isinstance(loaded, dict):
                raise ValueError("not a JSON object")
        except (OSError, ValueError) as err:
            broken = "%s.broken-%d" % (self.path, int(time.time()))
            try:
                os.replace(self.path, broken)
            except OSError:
                broken = "(could not be moved)"
            print("WARNING: %s is unreadable (%s); starting empty. The old file is %s"
                  % (self.path, err, broken), file=sys.stderr)
            return data
        for key, default in data.items():
            value = loaded.get(key)
            if default is not None and isinstance(value, type(default)):
                data[key] = value
        if loaded.get("generation") in GENERATION_NAMES:
            data["generation"] = loaded["generation"]
        return data

    def save(self):
        with self.lock:
            text = json.dumps(self.data, indent=1, sort_keys=True)
            folder = os.path.dirname(os.path.abspath(self.path))
            os.makedirs(folder, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".gts_data.", suffix=".tmp", dir=folder)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(text)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, self.path)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise

    # ---- requests -----------------------------------------------------------

    def compatible(self, client_version):
        mine = series(self.version)
        return mine is not None and series(client_version) == mine

    def mismatch(self):
        return {"success": False, "error": "VERSION_MISMATCH", "serverVersion": self.version}

    def wrong_generation(self):
        return {"success": False, "error": "WRONG_GENERATION",
                "serverGeneration": self.data["generation"]}

    def _admit(self, gen, may_claim):
        """Whether a client of generation `gen` belongs in this world.  The
        first known client of a world with no generation yet claims it."""
        if gen is None:
            return True     # not a game (a script or a test): nothing to check
        if gen not in GENERATION_NAMES:
            return False    # a generation the mod does not run on
        if self.data["generation"] is None and may_claim:
            self.data["generation"] = gen
            self.save()
            self.announce("This server is now a %s world (the first game to connect decided)."
                          % GENERATION_NAMES[gen])
        return self.data["generation"] in (None, gen)

    def handle_get(self, path, query, header_version=None):
        if path == "/server/info":
            # never version-gated: the client compares versions itself
            with self.lock:
                return {"success": True, "version": self.version, "modVersion": self.version,
                        "generation": self.data["generation"], "rules": self._run_view()}
        route = self.GET_ROUTES.get(path)
        if route is None:
            return {"success": False, "error": "NOT_FOUND"}
        version = query.get("modVersion") or query.get("version") or header_version
        if not self.compatible(version):
            return self.mismatch()
        with self.lock:
            # reads never claim a world; a client that names the wrong one is refused
            if not self._admit(generation_of(query.get("gen"), None), False):
                return self.wrong_generation()
            self._sweep()
            try:
                # a copy: the answer is serialized after the lock is released
                return copy.deepcopy(route(self, query))
            except ApiError as err:
                return {"success": False, "error": err.code}

    def handle_post(self, req, header_version=None):
        if not isinstance(req, dict):
            return {"success": False, "error": "BAD_JSON"}
        version = req.get("modVersion") or req.get("version") or header_version
        if not self.compatible(version):
            return self.mismatch()
        action = req.get("action")
        handler = self.ACTIONS.get(action) if isinstance(action, str) else None
        if handler is None:
            return {"success": False, "error": "UNKNOWN_ACTION"}
        with self.lock:
            gen = generation_of(req.get("generation"), req.get("gameVersion"))
            if not self._admit(gen, True):
                return self.wrong_generation()
            if (gen in MODES_GENERATIONS and to_int(req.get("modesVersion"), 0) < MODES_VERSION
                    and action != "logout" and self._run_view()["active"]):
                return {"success": False, "error": "VERSION_MISMATCH",
                        "serverVersion": "%s+ (GAME MODES)" % self.version,
                        "modesVersion": MODES_VERSION}
            self._sweep()
            try:
                return copy.deepcopy(handler(self, req))
            except ApiError as err:
                return {"success": False, "error": err.code}

    # ---- expiry -------------------------------------------------------------

    def _sweep(self):
        now = self.clock()
        if now >= self._next_sweep:
            self._next_sweep = now + 1
            for tid in [t for t, p in self.presence.items() if now - p["seen"] > PRESENCE_TTL]:
                del self.presence[tid]
            for tid in [t for t, c in self.challenges.items() if now >= c["expires"]]:
                del self.challenges[tid]
            for tid in [t for t, i in self.invites.items() if now >= i["expires"]]:
                del self.invites[tid]
            for rid in [r for r, room in self.rooms.items() if now - room["touched"] > ROOM_IDLE_TTL]:
                del self.rooms[rid]
            for pid in list(self.parties):
                members = self.parties[pid]["members"]
                if all(now - self.last_seen.get(m, 0) > PARTY_IDLE_TTL for m in members):
                    for m in list(members):
                        self._leave_party(m)
        if now >= self._next_slow_sweep:
            self._next_slow_sweep = now + 60
            if self._expire_gts(now):
                self.save()

    def _expire_gts(self, now):
        changed = False
        listings = self.data["listings"]
        for lid in list(listings):
            listing = listings[lid]
            if now - to_int(listing.get("timestamp"), 0) > LISTING_TTL:
                # the mon goes home, not into the void
                del listings[lid]
                self._add_claim(listing.get("trainerId"), {
                    "mon": listing.get("offeredMon"),
                    "fromName": "GTS",
                    "fromId": tid_of(listing.get("trainerId")),
                    "originalOffered": mon_name(listing.get("offeredMon")),
                    "timestamp": int(now),
                })
                changed = True
        for tid, claims in list(self.data["claims"].items()):
            kept = [c for c in claims if now - to_int(c.get("timestamp"), 0) <= CLAIM_TTL]
            if len(kept) != len(claims):
                changed = True
                if kept:
                    self.data["claims"][tid] = kept
                else:
                    del self.data["claims"][tid]
        return changed

    # ---- shared bits ----------------------------------------------------------

    def _now(self):
        return int(self.clock())

    def _account(self, tid):
        return self.data["accounts"].get(tid_of(tid))

    def _require_account(self, req, key="trainerId"):
        account = self._account(req.get(key))
        if account is None:
            raise ApiError("UNKNOWN_TRAINER")
        token = req.get("token")
        if token and str(token).strip().upper() != account["token"]:
            raise ApiError("INVALID_TOKEN")
        return account

    def _name_taken(self, name, except_tid=None):
        wanted = fold(name)
        for tid, account in self.data["accounts"].items():
            if tid != except_tid and fold(account.get("name")) == wanted:
                return True
        return False

    def _display_name(self, tid, given=None):
        name = clean_text(given, NAME_MAX_LEN)
        if name:
            return name
        account = self._account(tid)
        return account["name"] if account else "TRAINER"

    def _history(self, text):
        history = self.data["history"]
        history.insert(0, {"text": text, "time": self._now()})
        del history[HISTORY_KEEP:]

    def _add_claim(self, tid, claim):
        tid = tid_of(tid)
        claim["id"] = self.data["nextClaimId"]
        self.data["nextClaimId"] += 1
        self.data["claims"].setdefault(tid, []).append(claim)

    def _account_view(self, account):
        view = {k: account.get(k) for k in (
            "trainerId", "name", "token", "level", "xp", "spriteId", "title",
            "favoriteMon", "badges", "pokedexCount", "pvpWins", "pvpLosses",
            "gtsTrades", "blackouts")}
        view["blackoutCount"] = account.get("blackouts", 0)
        return view

    @staticmethod
    def _rank_key(account):
        return (to_int(account.get("level"), 1), to_int(account.get("xp")),
                to_int(account.get("pvpWins")), to_int(account.get("badges")),
                to_int(account.get("pokedexCount")))

    def _profile(self, account):
        accounts = self.data["accounts"].values()
        mine = self._rank_key(account)
        ahead = sum(1 for other in accounts if self._rank_key(other) > mine)
        level = to_int(account.get("level"), 1)
        return {
            "trainerId": account["trainerId"],
            "name": account.get("name"),
            "level": level,
            "xp": to_int(account.get("xp")),
            "pvpWins": to_int(account.get("pvpWins")),
            "pvpLosses": to_int(account.get("pvpLosses")),
            "gtsTrades": to_int(account.get("gtsTrades")),
            "serverRank": ahead + 1,
            "totalPlayers": len(self.data["accounts"]),
            "rank": rank_title(level),
            "badges": to_int(account.get("badges")),
            "pokedexCount": to_int(account.get("pokedexCount")),
            "favoriteMon": account.get("favoriteMon"),
            "title": account.get("title"),
            "blackouts": to_int(account.get("blackouts")),
            "spriteId": account.get("spriteId"),
        }

    # ---- GET ----------------------------------------------------------------

    def get_chat_history(self, query):
        return {"success": True, "messages": self.data["chat"][-CHAT_HISTORY_SENT:]}

    def get_browse(self, query):
        return {"success": True, "listings": self.data["listings"],
                "history": self.data["history"]}

    def get_claims(self, query):
        claims = self.data["claims"].get(tid_of(query.get("trainerId")), [])
        return {"success": True, "claims": claims}

    def get_players(self, query):
        return {"success": True,
                "players": {tid: p["entry"] for tid, p in self.presence.items()}}

    def get_profile(self, query):
        account = self._account(query.get("trainerId"))
        if account is None:
            raise ApiError("UNKNOWN_TRAINER")
        return {"success": True, "profile": self._profile(account)}

    def get_check_name(self, query):
        name = query.get("name") or ""
        return {"success": True, "taken": bool(name.strip()) and self._name_taken(name)}

    # ---- accounts -------------------------------------------------------------

    def act_register_player(self, req):
        name = clean_text(req.get("name"), NAME_MAX_LEN)
        if not name:
            raise ApiError("BAD_NAME")
        if self._name_taken(name):
            raise ApiError("NAME_TAKEN")
        accounts = self.data["accounts"]
        while True:
            tid = str(100001 + secrets.randbelow(899999))
            if tid not in accounts:
                break
        tokens = {a.get("token") for a in accounts.values()}
        alphabet = TOKEN_ALPHABETS.get(self.data["generation"], TOKEN_ALPHABETS[2])
        while True:
            token = "".join(secrets.choice(alphabet) for _ in range(TOKEN_LENGTH))
            if token not in tokens:
                break
        now = self._now()
        account = {
            "trainerId": tid,
            "name": name,
            "token": token,
            "level": 1,
            "xp": 0,
            "spriteId": clean_text(req.get("spriteId"), 40) or "SPRITE_CHRIS",
            "title": clean_text(req.get("title"), 24) or "ACE TRAINER",
            "favoriteMon": clean_text(req.get("favoriteMon"), 24) or "PIKACHU",
            "badges": max(0, to_int(req.get("badges"))),
            "pokedexCount": max(0, to_int(req.get("pokedexCount"))),
            "pvpWins": 0,
            "pvpLosses": 0,
            "gtsTrades": 0,
            "blackouts": 0,
            "wildBattles": 0,
            "trainerBattles": 0,
            "catches": 0,
            "created": now,
            "lastSeen": now,
        }
        accounts[tid] = account
        self.save()
        return {"success": True, "account": self._account_view(account)}

    def act_login_player(self, req):
        account = self._account(req.get("trainerId"))
        token = str(req.get("token") or "").strip().upper()
        if account is None or not token or token != account["token"]:
            raise ApiError("INVALID_LOGIN")
        account["lastSeen"] = self._now()
        self.save()
        return {"success": True, "account": self._account_view(account)}

    def act_redeem_token(self, req):
        token = str(req.get("token") or "").strip().upper()
        if token:
            for account in self.data["accounts"].values():
                if account["token"] == token:
                    account["lastSeen"] = self._now()
                    self.save()
                    return {"success": True, "account": self._account_view(account)}
        raise ApiError("TOKEN_NOT_FOUND")

    def act_update_profile(self, req):
        account = self._require_account(req)
        name = clean_text(req.get("name"), NAME_MAX_LEN)
        if name and not self._name_taken(name, except_tid=account["trainerId"]):
            account["name"] = name
        for key, limit in (("title", 24), ("spriteId", 40), ("favoriteMon", 24)):
            value = clean_text(req.get(key), limit)
            if value:
                account[key] = value
        for key in ("badges", "pokedexCount", "blackouts"):
            if req.get(key) is not None:
                account[key] = max(0, to_int(req.get(key)))
        # pvpWins arrives as a delta right after sync_xp pvp_win, which already
        # counted the win: it is ignored here so a win counts once
        account["lastSeen"] = self._now()
        self.save()
        return {"success": True, "profile": self._profile(account)}

    def act_sync_xp(self, req):
        account = self._require_account(req)
        xp_type = str(req.get("xpType") or "")
        if req.get("xp") is not None:
            delta = min(XP_MAX_DELTA, max(0, to_int(req.get("xp"))))
        else:
            delta = XP_TABLE.get(xp_type, XP_DEFAULT)
        old_level = to_int(account.get("level"), 1)
        account["xp"] = to_int(account.get("xp")) + delta
        account["level"] = level_for_xp(account["xp"])
        for key in ("badges", "pokedexCount"):
            if req.get(key) is not None:
                account[key] = max(0, to_int(req.get(key)))
        if xp_type == "pvp_win":
            account["pvpWins"] = to_int(account.get("pvpWins")) + 1
            opponent = clean_text(req.get("opponentName"), NAME_MAX_LEN) or "TRAINER"
            self._history("%s DEFEATED %s IN PVP!" % (account["name"], opponent))
        elif xp_type == "pvp_loss":
            account["pvpLosses"] = to_int(account.get("pvpLosses")) + 1
        elif xp_type == "wild_battle":
            account["wildBattles"] = to_int(account.get("wildBattles")) + 1
        elif xp_type == "trainer_battle":
            account["trainerBattles"] = to_int(account.get("trainerBattles")) + 1
        elif xp_type == "catch":
            account["catches"] = to_int(account.get("catches")) + 1
        account["lastSeen"] = self._now()
        self.save()
        return {"success": True, "level": account["level"], "xp": account["xp"],
                "leveledUp": account["level"] > old_level}

    def act_report_battle_stat(self, req):
        # sync_xp already counts battles and catches; nothing else is kept
        return {"success": True}

    def act_logout(self, req):
        tid = tid_of(req.get("trainerId"))
        self.presence.pop(tid, None)
        self._leave_party(tid)
        return {"success": True}

    # ---- presence -------------------------------------------------------------

    def act_sync_pos(self, req):
        tid = tid_of(req.get("trainerId"))
        if not tid:
            raise ApiError("BAD_REQUEST")
        now = self.clock()
        session = str(req.get("sessionId") or "")
        current = self.presence.get(tid)
        if (current and session and current["session"] and current["session"] != session
                and now - current["seen"] < SESSION_LOCK):
            raise ApiError("ALREADY_LOGGED_IN")
        if current is None:
            current = {"entry": {}, "session": "", "seen": now}
            self.presence[tid] = current
        entry = current["entry"]
        for key in PRESENCE_FIELDS:
            if req.get(key) is not None:
                entry[key] = req[key]
        entry["trainerId"] = tid
        entry["timestamp"] = int(now)
        if session:
            current["session"] = session
        current["seen"] = now
        self.last_seen[tid] = now

        party = self._party_for(tid)
        if party is not None:
            member = party["members"].get(tid)
            if member is not None:
                for key in ("name", "level", "map"):
                    if entry.get(key) is not None:
                        member[key] = entry[key]

        here = str(entry.get("map", "")).lower()
        others = [p for other, p in self.presence.items()
                  if other != tid and str(p["entry"].get("map", "")).lower() == here]
        others.sort(key=lambda p: p["seen"], reverse=True)
        challenge = self.challenges.get(tid)
        invite = self.invites.get(tid)
        clock = time.localtime(now)
        return {
            "success": True,
            "players": [p["entry"] for p in others[:MAX_PLAYERS_PER_MAP]],
            "challenge": challenge["challenge"] if challenge else None,
            "partyInvite": ({"fromId": invite["fromId"], "fromName": invite["fromName"]}
                            if invite else None),
            "partyXp": [],
            "party": self._party_view(party),
            "serverHour": clock.tm_hour,
            "serverMinute": clock.tm_min,
            "serverWeekday": (clock.tm_wday + 1) % 7,   # 0 = Sunday
            "run": self._run_view(),
            "team": self._team_view(),
        }

    # ---- chat -------------------------------------------------------------------

    def act_send_chat(self, req):
        text = clean_text(req.get("text"), CHAT_MAX_LEN)
        if not text:
            raise ApiError("EMPTY_MESSAGE")
        tid = tid_of(req.get("trainerId"))
        message = {
            "id": self.data["nextChatId"],
            "trainerId": tid,
            "name": self._display_name(tid, req.get("name")),
            "text": text,
            "scope": clean_text(req.get("scope"), 16) or "global",
            "time": self._now(),
        }
        self.data["nextChatId"] += 1
        chat = self.data["chat"]
        chat.append(message)
        del chat[:-CHAT_KEEP]
        self.save()
        return {"success": True, "message": message}

    # ---- challenges and battle rooms ---------------------------------------------

    def act_send_challenge(self, req):
        target = tid_of(req.get("targetId"))
        kind = req.get("challengeType")
        if not target or kind not in CHALLENGE_TYPES:
            raise ApiError("BAD_REQUEST")
        from_id = tid_of(req.get("fromId"))
        self.challenges[target] = {
            "challenge": {
                "fromId": from_id,
                "fromName": self._display_name(from_id, req.get("fromName")),
                "type": kind,
                "party": req.get("party"),
                "seed": req.get("seed"),
                "roomId": req.get("roomId"),   # verbatim: native PVP negotiates on it
            },
            "expires": self.clock() + CHALLENGE_TTL,
        }
        return {"success": True}

    def act_clear_challenge(self, req):
        self.challenges.pop(tid_of(req.get("trainerId")), None)
        return {"success": True}

    def act_send_battle_msg(self, req):
        room_id = req.get("roomId")
        target = tid_of(req.get("targetId"))
        if not isinstance(room_id, str) or not room_id or not target:
            raise ApiError("BAD_REQUEST")
        room = self.rooms.setdefault(room_id, {"inboxes": {}, "touched": 0})
        room["touched"] = self.clock()
        inbox = room["inboxes"].setdefault(target, [])
        inbox.append(req.get("msg"))
        del inbox[:-MAX_INBOX]
        return {"success": True}

    def act_poll_battle_msgs(self, req):
        room = self.rooms.get(req.get("roomId")) if isinstance(req.get("roomId"), str) else None
        if room is None:
            return {"success": True, "msgs": []}
        room["touched"] = self.clock()
        msgs = room["inboxes"].pop(tid_of(req.get("myId")), [])
        return {"success": True, "msgs": msgs}

    def act_clear_battle_room(self, req):
        if isinstance(req.get("roomId"), str):
            self.rooms.pop(req["roomId"], None)
        return {"success": True}

    # ---- GTS ------------------------------------------------------------------------

    def act_deposit(self, req):
        tid = tid_of(req.get("trainerId"))
        mon = req.get("offeredMon")
        if not tid:
            raise ApiError("BAD_REQUEST")
        if not valid_mon(mon):
            raise ApiError("BAD_MON")
        listings = self.data["listings"]
        if sum(1 for l in listings.values() if l.get("trainerId") == tid) >= MAX_LISTINGS_PER_TRAINER:
            raise ApiError("LISTING_LIMIT")
        wanted = req.get("wanted")
        # species names on Gen 1 and Crystal, species numbers on FireRed/LeafGreen
        wanted = [s for s in wanted if (isinstance(s, str) and s)
                  or (isinstance(s, int) and not isinstance(s, bool) and s > 0)][:MAX_WANTED] \
            if isinstance(wanted, list) else []
        listing_id = "GTS_%d" % self.data["nextListingId"]
        self.data["nextListingId"] += 1
        name = self._display_name(tid, req.get("trainerName"))
        listing = {
            "id": listing_id,
            "trainerId": tid,
            "trainerName": name,
            "offeredMon": mon,
            "wanted": wanted,
            "timestamp": self._now(),
        }
        listings[listing_id] = listing
        self._history("%s DEPOSITED %s" % (name, mon_name(mon)))
        self.save()
        return {"success": True, "listing": listing}

    def act_trade(self, req):
        listing = self.data["listings"].get(str(req.get("listingId") or ""))
        buyer = tid_of(req.get("buyerId"))
        sent = req.get("sentMon")
        if listing is None:
            raise ApiError("LISTING_GONE")
        if not buyer:
            raise ApiError("BAD_REQUEST")
        if buyer == listing["trainerId"]:
            raise ApiError("OWN_LISTING")
        if not valid_mon(sent):
            raise ApiError("BAD_MON")
        if listing.get("wanted") and sent.get("species") not in listing["wanted"]:
            raise ApiError("NOT_WANTED")
        del self.data["listings"][listing["id"]]
        buyer_name = self._display_name(buyer, req.get("buyerName"))
        offered = listing["offeredMon"]
        self._add_claim(listing["trainerId"], {
            "mon": sent,
            "fromName": buyer_name,
            "fromId": buyer,
            "originalOffered": mon_name(offered),
            "timestamp": self._now(),
        })
        for tid in (buyer, listing["trainerId"]):
            account = self._account(tid)
            if account is not None:
                account["gtsTrades"] = to_int(account.get("gtsTrades")) + 1
        self._history("%s TRADED %s TO %s FOR %s" % (
            buyer_name, mon_name(sent), listing.get("trainerName") or "TRAINER", mon_name(offered)))
        self.save()
        return {"success": True, "receivedMon": offered}

    def act_withdraw(self, req):
        listing = self.data["listings"].get(str(req.get("listingId") or ""))
        if listing is None:
            raise ApiError("LISTING_GONE")
        if listing["trainerId"] != tid_of(req.get("trainerId")):
            raise ApiError("NOT_YOUR_LISTING")
        del self.data["listings"][listing["id"]]
        self._history("%s WITHDREW %s" % (listing.get("trainerName") or "TRAINER",
                                          mon_name(listing["offeredMon"])))
        self.save()
        return {"success": True, "mon": listing["offeredMon"]}

    def act_claim(self, req):
        tid = tid_of(req.get("trainerId"))
        claims = self.data["claims"].get(tid) or []
        index = None
        if req.get("claimId") is not None:
            wanted_id = to_int(req.get("claimId"), -1)
            for i, claim in enumerate(claims):
                if to_int(claim.get("id"), -2) == wanted_id:
                    index = i
                    break
        else:
            i = to_int(req.get("index"), -1)
            if 0 <= i < len(claims):
                index = i
        if index is None:
            raise ApiError("NO_CLAIM")
        claimed = claims.pop(index)
        if not claims:
            self.data["claims"].pop(tid, None)
        self._history("%s CLAIMED %s" % (self._display_name(tid), mon_name(claimed.get("mon"))))
        self.save()
        return {"success": True, "claimed": claimed}

    # ---- Wonder Trade ---------------------------------------------------------------

    def _wonder_entry(self, tid):
        for entry in self.data["wonderPool"]:
            if entry.get("trainerId") == tid:
                return entry
        return None

    def act_wonder_trade_status(self, req):
        tid = tid_of(req.get("trainerId"))
        mine = self._wonder_entry(tid)
        return {
            "success": True,
            "poolCount": len(self.data["wonderPool"]),
            "threshold": WONDER_THRESHOLD,
            "mine": ({"offeredMon": mine["offeredMon"], "timestamp": mine["timestamp"]}
                     if mine else None),
            "claim": self.data["wonderClaims"].get(tid),
        }

    def act_wonder_trade_deposit(self, req):
        tid = tid_of(req.get("trainerId"))
        mon = req.get("offeredMon")
        if not tid:
            raise ApiError("BAD_REQUEST")
        if not valid_mon(mon):
            raise ApiError("BAD_MON")
        if self._wonder_entry(tid) is not None:
            raise ApiError("ALREADY_IN_POOL")
        if tid in self.data["wonderClaims"]:
            raise ApiError("CLAIM_PENDING")
        pool = self.data["wonderPool"]
        pool.append({
            "trainerId": tid,
            "trainerName": self._display_name(tid, req.get("trainerName")),
            "offeredMon": mon,
            "timestamp": self._now(),
        })
        matched = False
        # a claim is never overwritten: only entries without one take part
        ready = [e for e in pool if e["trainerId"] not in self.data["wonderClaims"]]
        if len(ready) >= WONDER_THRESHOLD:
            self.rng.shuffle(ready)
            now = self._now()
            count = len(ready)
            for i, giver in enumerate(ready):
                receiver = ready[(i + 1) % count]   # a cycle: nobody gets their own
                self.data["wonderClaims"][receiver["trainerId"]] = {
                    "mon": giver["offeredMon"],
                    "fromName": giver["trainerName"],
                    "fromId": giver["trainerId"],
                    "sentMon": receiver["offeredMon"],
                    "timestamp": now,
                }
            taken = {e["trainerId"] for e in ready}
            pool[:] = [e for e in pool if e["trainerId"] not in taken]
            self._history("WONDER TRADE MATCHED %d TRAINERS!" % count)
            matched = True
        self.save()
        return {"success": True, "poolCount": len(pool), "matched": matched}

    def act_wonder_trade_withdraw(self, req):
        tid = tid_of(req.get("trainerId"))
        entry = self._wonder_entry(tid)
        if entry is None:
            raise ApiError("NOT_IN_POOL")
        self.data["wonderPool"].remove(entry)
        self.save()
        return {"success": True, "mon": entry["offeredMon"]}

    def act_wonder_trade_claim(self, req):
        claim = self.data["wonderClaims"].pop(tid_of(req.get("trainerId")), None)
        if claim is None:
            raise ApiError("NO_CLAIM")
        self.save()
        return {"success": True, "claim": claim}

    # ---- parties ----------------------------------------------------------------------

    def _party_for(self, tid):
        pid = self.party_of.get(tid)
        return self.parties.get(pid) if pid is not None else None

    @staticmethod
    def _party_view(party):
        if party is None:
            return None
        return {"leaderId": party["leaderId"],
                "members": {tid: dict(m) for tid, m in party["members"].items()}}

    def _member_info(self, tid, req):
        entry = self.presence.get(tid, {}).get("entry", {})
        return {
            "name": self._display_name(tid, req.get("name") or entry.get("name")),
            "level": to_int(req.get("level") if req.get("level") is not None
                            else entry.get("level"), 1),
            "map": req.get("map") if req.get("map") is not None else entry.get("map"),
        }

    def _leave_party(self, tid):
        pid = self.party_of.pop(tid, None)
        party = self.parties.get(pid)
        if party is None:
            return
        party["members"].pop(tid, None)
        if not party["members"]:
            del self.parties[pid]
            for target in [t for t, i in self.invites.items() if i["partyId"] == pid]:
                del self.invites[target]
        elif party["leaderId"] == tid:
            party["leaderId"] = sorted(party["members"])[0]

    def _create_party(self, tid, req):
        self._leave_party(tid)
        pid = self.next_party_id
        self.next_party_id += 1
        self.parties[pid] = {"leaderId": tid, "members": {tid: self._member_info(tid, req)}}
        self.party_of[tid] = pid
        self.last_seen[tid] = self.clock()
        return self.parties[pid]

    def act_party_create(self, req):
        tid = tid_of(req.get("trainerId"))
        if not tid:
            raise ApiError("BAD_REQUEST")
        return {"success": True, "party": self._party_view(self._create_party(tid, req))}

    def act_party_invite(self, req):
        tid = tid_of(req.get("trainerId"))
        target = tid_of(req.get("targetId"))
        if not tid or not target or target == tid:
            raise ApiError("BAD_REQUEST")
        party = self._party_for(tid) or self._create_party(tid, req)
        if target in party["members"]:
            raise ApiError("ALREADY_IN_PARTY")
        if len(party["members"]) >= MAX_PARTY:
            raise ApiError("PARTY_FULL")
        self.invites[target] = {
            "fromId": tid,
            "fromName": self._display_name(tid, req.get("name")),
            "partyId": self.party_of[tid],
            "expires": self.clock() + INVITE_TTL,
        }
        return {"success": True, "party": self._party_view(party)}

    def act_party_accept(self, req):
        tid = tid_of(req.get("trainerId"))
        invite = self.invites.pop(tid, None)
        party = self.parties.get(invite["partyId"]) if invite else None
        if party is None:
            raise ApiError("NO_INVITE")
        if len(party["members"]) >= MAX_PARTY:
            raise ApiError("PARTY_FULL")
        pid = invite["partyId"]
        if self.party_of.get(tid) != pid:
            self._leave_party(tid)
        party["members"][tid] = self._member_info(tid, req)
        self.party_of[tid] = pid
        self.last_seen[tid] = self.clock()
        return {"success": True, "party": self._party_view(party)}

    def act_party_decline(self, req):
        self.invites.pop(tid_of(req.get("trainerId")), None)
        return {"success": True}

    def act_party_leave(self, req):
        self._leave_party(tid_of(req.get("trainerId")))
        return {"success": True}

    def act_party_warp_target(self, req):
        p = self.presence.get(tid_of(req.get("targetId")))
        if p is None or p["entry"].get("map") is None:
            raise ApiError("NOT_ONLINE")
        entry = p["entry"]
        return {"success": True, "map": entry.get("map"), "x": entry.get("x"), "y": entry.get("y")}

    # ---- game modes: the run and the team's shared key items --------------------------
    #
    # The server keeps three things for the modes in server_config.txt: the rules,
    # the current run (a number and the randomizer's seed for it) and the key
    # items, HMs and badges the team has found.  Everything else -- what the seed
    # shuffles, which encounters count, what a faint means -- is the clients'.

    def _run_seed(self, run_id):
        seed = self.rules.get("seed")
        if not seed:
            return self.rng.randint(1, SEED_MAX)
        # a fixed seed replays run 1 exactly; later runs get their own world
        return seed if run_id == 1 else (seed * 1000003 + run_id) % SEED_MAX + 1

    def _begin_run(self, run_id):
        old = self.data.get("run") or {}
        self.data["run"] = {"id": run_id, "seed": self._run_seed(run_id),
                            "started": self._now(),
                            # a multiworld team keeps its worlds from run to run
                            "worlds": old.get("worlds") or {},
                            "fingerprint": old.get("fingerprint"),
                            "gameName": old.get("gameName")}
        self.data["team"] = {"items": {}, "rev": 0}
        self.save()

    def _run_view(self):
        run = self.data["run"]
        view = rules_view(self.rules)
        view["runId"] = run.get("id", 1)
        view["seed"] = run.get("seed")
        return view

    def _team_view(self):
        team = self.data["team"]
        return {"rev": team.get("rev", 0), "items": sorted(team.get("items", {}))}

    def _check_run(self, req):
        run_id = to_int(req.get("runId"), 0)
        if run_id != self.data["run"].get("id"):
            raise ApiError("RUN_OVER")

    def act_team_status(self, req):
        return {"success": True, "run": self._run_view(), "team": self._team_view()}

    def act_team_found(self, req):
        """A teammate found a key item, HM or badge: the whole team has it now."""
        account = self._require_account(req)
        if not rules_view(self.rules)["sharedKeyItems"]:
            raise ApiError("NOT_SHARED")
        self._check_run(req)
        item = clean_text(req.get("item"), 32).upper()
        if not re.match(r"^[A-Z0-9_]+$", item):
            raise ApiError("BAD_REQUEST")
        items = self.data["team"].setdefault("items", {})
        first = item not in items
        if first:
            if len(items) >= TEAM_ITEM_MAX:
                raise ApiError("TEAM_FULL")
            items[item] = {"by": account["trainerId"], "name": account["name"],
                           "time": self._now(),
                           "location": clean_text(req.get("location"), LOCATION_MAX_LEN)}
            self.data["team"]["rev"] = self.data["team"].get("rev", 0) + 1
            self._history("%s FOUND %s FOR THE TEAM!"
                          % (account["name"], clean_text(req.get("itemName"), 20) or item))
            self.save()
        return {"success": True, "first": first, "team": self._team_view()}

    def act_run_wipe(self, req):
        """Hardcore Nuzlocke: a teammate's party wiped out, so the run is over for
        everyone.  A wipe from a run that already ended starts nothing new."""
        account = self._require_account(req)
        if rules_view(self.rules)["nuzlocke"] != "hardcore":
            raise ApiError("NOT_NUZLOCKE")
        run = self.data["run"]
        if to_int(req.get("runId"), 0) == run.get("id"):
            ended = run.get("id", 1)
            self._history("%s'S PARTY WIPED OUT! RUN %d IS OVER." % (account["name"], ended))
            self.announce("Run %d ended: %s's party wiped out. Run %d begins."
                          % (ended, account["name"], ended + 1))
            self._begin_run(ended + 1)
        return {"success": True, "run": self._run_view(), "team": self._team_view()}

    def act_run_join(self, req):
        """Multiworld: this trainer's world (1..players), claimed first come.
        Without a trainerId it only checks there is room and the data matches
        (CONNECT asks before anything changes)."""
        view = rules_view(self.rules)
        run = self.data["run"]
        worlds = run.setdefault("worlds", {})
        tid = tid_of(req.get("trainerId"))
        account = self._require_account(req) if tid else None
        players = view["players"]
        if players <= 1:
            return {"success": True, "world": 1, "players": 1, "run": self._run_view()}
        if account and account["trainerId"] in worlds:
            return {"success": True, "world": worlds[account["trainerId"]],
                    "players": players, "run": self._run_view()}
        fingerprint = to_int(req.get("fingerprint"), 0)
        if run.get("fingerprint") and fingerprint != run["fingerprint"]:
            return {"success": False, "error": "WRONG_WORLD_DATA",
                    "gameName": run.get("gameName") or "another game"}
        taken = set(worlds.values())
        free = [w for w in range(1, players + 1) if w not in taken]
        if not free:
            return {"success": False, "error": "RUN_FULL", "players": players}
        if account is None:
            return {"success": True, "world": None, "players": players, "free": len(free),
                    "run": self._run_view()}
        world = free[0]
        worlds[account["trainerId"]] = world
        if not run.get("fingerprint"):
            run["fingerprint"] = fingerprint
            run["gameName"] = clean_text(req.get("gameName"), 24) or None
        self._history("%s JOINED THE RUN AS WORLD %d!" % (account["name"], world))
        self.save()
        return {"success": True, "world": world, "players": players, "run": self._run_view()}

    def new_run(self):
        """Start the next run by hand (the --new-run option)."""
        with self.lock:
            self._begin_run(self.data["run"].get("id", 0) + 1)

    # ---- quests ---------------------------------------------------------------------

    def act_get_quests(self, req):
        return {"success": True, "quests": []}

    GET_ROUTES = {
        "/chat/history": get_chat_history,
        "/gts/browse": get_browse,
        "/gts/claims": get_claims,
        "/gts/players": get_players,
        "/gts/profile": get_profile,
        "/player/check_name": get_check_name,
    }



# every act_<name> method answers the POST action <name>
GtsStore.ACTIONS = {name[4:]: getattr(GtsStore, name)
                    for name in dir(GtsStore) if name.startswith("act_")}


# --------------------------------------------------------------------------
# HTTP

class GtsHandler(BaseHTTPRequestHandler):
    # HTTP/1.1: the client's async engine reuses keep-alive connections, and
    # its synchronous helpers send Connection: close and read to EOF.
    protocol_version = "HTTP/1.1"
    server_version = "Gen1OnlineServer"
    timeout = 300   # an idle keep-alive connection is closed after this

    def version_string(self):
        return self.server_version

    def log_message(self, fmt, *args):
        pass   # no request log: nothing about who connected is kept

    def _reply(self, obj):
        try:
            body = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8", "surrogateescape")
        except UnicodeEncodeError:
            body = json.dumps(obj, separators=(",", ":")).encode("ascii")
        # Always 200: the client treats any status >= 400 as a dead transport
        # and re-sends the request over raw TCP.
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _path(self):
        parts = urlsplit(self.path)
        path = re.sub(r"/+", "/", parts.path).rstrip("/") or "/"
        return path, parts.query

    def _read_body(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            chunks, total = [], 0
            while True:
                size_line = self.rfile.readline(65537)
                size = int(size_line.split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                        pass
                    break
                total += size
                if total > MAX_BODY:
                    raise ValueError("body too large")
                chunks.append(self.rfile.read(size))
                self.rfile.readline(65537)
            return b"".join(chunks)
        length = to_int(self.headers.get("Content-Length"), 0)
        if length < 0 or length > MAX_BODY:
            raise ValueError("body too large")
        return self.rfile.read(length) if length else b""

    def _guard(self, fn):
        try:
            self._reply(fn())
        except Exception:
            traceback.print_exc()
            self.close_connection = True
            try:
                self._reply({"success": False, "error": "SERVER_ERROR"})
            except Exception:
                pass

    def do_GET(self):
        def run():
            path, query_string = self._path()
            query = {k: v[-1] for k, v in parse_qs(
                query_string, keep_blank_values=True, encoding="utf-8",
                errors="surrogateescape").items()}
            return self.server.store.handle_get(path, query, self.headers.get("X-Mod-Version"))
        self._guard(run)

    def do_POST(self):
        def run():
            path, _ = self._path()
            try:
                raw = self._read_body()
            except ValueError:
                self.close_connection = True
                return {"success": False, "error": "BAD_REQUEST"}
            if path != "/gts":
                return {"success": False, "error": "NOT_FOUND"}
            try:
                req = json.loads(raw.decode("utf-8", "surrogateescape"))
            except ValueError:
                return {"success": False, "error": "BAD_JSON"}
            return self.server.store.handle_post(req, self.headers.get("X-Mod-Version"))
        self._guard(run)


class GtsHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    # On Windows SO_REUSEADDR lets a second server bind a port that is already
    # in use, so two servers would silently share one data file: there the
    # second start must fail instead.
    allow_reuse_address = os.name != "nt"

    def __init__(self, address, store):
        self.store = store
        ThreadingHTTPServer.__init__(self, address, GtsHandler)


# --------------------------------------------------------------------------
# start-up

def lan_ip():
    """This machine's LAN address: a UDP connect picks the route, sends nothing."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()
    return None if ip.startswith("127.") or ip == "0.0.0.0" else ip


def tailscale_ip():
    try:
        out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    for line in out.stdout.split():
        if re.match(r"^\d+\.\d+\.\d+\.\d+$", line.strip()):
            return line.strip()
    return None


def modes_line(store):
    view = store._run_view()
    if not view["active"]:
        return "none (edit %s to play a Nuzlocke or a randomizer)" % os.path.basename(DEFAULT_CONFIG)
    parts = []
    if view["nuzlocke"] != "off":
        parts.append("%s Nuzlocke" % view["nuzlocke"])
    if view["randomizer"]:
        shuffled = [name for name in ("encounters", "items", "badges", "starters") if view[name]]
        parts.append("randomizer (%s)" % (", ".join(shuffled) or "nothing shuffled"))
    if view["multiworld"]:
        parts.append("multiworld for %d players" % view["players"])
    if view["sharedKeyItems"]:
        parts.append("shared key items")
    return "%s; run %d, seed %s" % (", ".join(parts), view["runId"], view["seed"])


def banner(host, port, store):
    gen = store.data["generation"]
    world = (GENERATION_NAMES[gen] if gen else
             "not set yet: the first game to connect decides (or start with --gen 1, 2 or 3)")
    lines = ["Gen1Online+ server %s on %s:%d" % (store.version, host, port),
             "Data: %s" % os.path.abspath(store.path),
             "World: %s" % world,
             "Modes: %s" % modes_line(store),
             "",
             "Put one of these lines in gts_config.txt (next to the mod's main.lua):"]
    urls = [("this PC", "127.0.0.1")]
    if host in ("0.0.0.0", ""):
        ip, ts = lan_ip(), tailscale_ip()
        if ip and ip != ts:
            urls.append(("same Wi-Fi/LAN", ip))
        if ts:
            urls.append(("Tailscale", ts))
    elif not host.startswith("127."):
        urls = [("this address", host)]
    for label, ip in urls:
        lines.append("  %-15s server_url=http://%s:%d" % (label + ":", ip, port))
    lines.append("")
    lines.append("Over the internet: forward TCP %d on your router and give friends"
                 " server_url=http://<your public IP>:%d (or use Tailscale)." % (port, port))
    lines.append("Press Ctrl+C to stop.")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Gen1Online+ server for playing with friends.")
    parser.add_argument("--host", default="0.0.0.0",
                        help="address to listen on (default 0.0.0.0: every network)")
    parser.add_argument("--port", type=int, default=to_int(os.environ.get("PORT"), DEFAULT_PORT),
                        help="TCP port (default 7779, or $PORT)")
    parser.add_argument("--data", default=os.environ.get("GTS_DB_PATH") or DEFAULT_DATA,
                        help="JSON data file (default server/gts_data.json, or $GTS_DB_PATH)")
    env_gen = to_int(os.environ.get("GTS_GENERATION"), 0) or None
    parser.add_argument("--gen", type=int, choices=(1, 2, 3), default=env_gen,
                        help="the world's generation: 1 = Red/Blue/Yellow, 2 = Crystal, "
                             "3 = FireRed/LeafGreen "
                             "(default: the first game to connect decides, or $GTS_GENERATION)")
    parser.add_argument("--config", default=os.environ.get("GTS_CONFIG") or DEFAULT_CONFIG,
                        help="game modes file (default server/server_config.txt, or $GTS_CONFIG)")
    parser.add_argument("--new-run", action="store_true",
                        help="end the current Nuzlocke/randomizer run and start the next one")
    args = parser.parse_args(argv)

    try:
        rules = load_rules(args.config)
    except (OSError, ValueError) as err:
        print("%s: %s" % (args.config, err), file=sys.stderr)
        return 1
    try:
        store = GtsStore(args.data, version=os.environ.get("GTS_MOD_VERSION") or DEFAULT_VERSION,
                         generation=args.gen, rules=rules)
    except ValueError as err:
        print(err, file=sys.stderr)
        return 1
    if args.new_run:
        store.new_run()
    try:
        httpd = GtsHTTPServer((args.host, args.port), store)
    except OSError as err:
        print("Could not listen on %s:%d: %s" % (args.host, args.port, err), file=sys.stderr)
        print("Is the server already running? Pick another port with --port.", file=sys.stderr)
        return 1
    print(banner(args.host, args.port, store), flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        httpd.server_close()
        store.save()
    return 0


if __name__ == "__main__":
    sys.exit(main())
