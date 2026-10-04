"""Tests for server/gts_server.py (stdlib unittest, no network beyond localhost).

    python3 -m unittest server/test_gts_server.py

Each test runs a real server on a free localhost port, over HTTP, with its
own data file and a fake clock.
"""

import contextlib
import http.client
import io
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gts_server  # noqa: E402

VERSION = "0.5.1"


class FakeClock:
    def __init__(self, t=1_800_000_000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def mon(species, level=5, **extra):
    m = {"species": species, "level": level, "nickname": species,
         "dvs": {"attack": 9, "defense": 8, "speed": 7, "special": 6},
         "moves": [{"id": "TACKLE", "pp": 35}], "ot": "OT", "otId": 1234}
    m.update(extra)
    return m


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="gts_test_")
        self.path = os.path.join(self.dir, "data.json")
        self.clock = FakeClock()
        self.start()

    def tearDown(self):
        self.stop()
        shutil.rmtree(self.dir, ignore_errors=True)

    generation = None   # a test class can start its server as --gen 1 or 2

    def start(self):
        self.store = gts_server.GtsStore(self.path, version=VERSION, clock=self.clock,
                                         generation=self.generation)
        self.store.announce = lambda text: None
        self.httpd = gts_server.GtsHTTPServer(("127.0.0.1", 0), self.store)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, args=(0.05,), daemon=True)
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(5)

    def restart(self):
        self.stop()
        self.start()

    # ---- requests ---------------------------------------------------------

    def request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            res = conn.getresponse()
            data = res.read()
            self.assertEqual(res.status, 200, "every answer is HTTP 200")
            self.assertEqual(int(res.getheader("Content-Length")), len(data))
            return json.loads(data.decode("utf-8"))
        finally:
            conn.close()

    game = "Pokemon Crystal"   # the gameVersion every post carries

    def post(self, action, version=VERSION, game=None, **fields):
        payload = dict(fields, action=action)
        if version is not None:
            payload.update(modVersion=version, version=version,
                           gameVersion=self.game if game is None else game, recompVersion="v1")
        return self.request("POST", "/gts", json.dumps(payload).encode("utf-8"),
                            {"Content-Type": "application/json", "X-Mod-Version": version or ""})

    def get(self, path, version=VERSION):
        if version is not None:
            path += ("&" if "?" in path else "?") + "version=%s&modVersion=%s" % (version, version)
        return self.request("GET", path, headers={"X-Mod-Version": version or ""})

    def register(self, name, **fields):
        res = self.post("register_player", isNewCharacter=True, name=name,
                        spriteId="SPRITE_CHRIS", title="ACE TRAINER", badges=0,
                        pokedexCount=0, **fields)
        self.assertTrue(res["success"], res)
        return res["account"]

    def sync(self, tid, session="s", **fields):
        payload = {"trainerId": tid, "sessionId": session, "name": "P" + str(tid),
                   "spriteId": "SPRITE_RED", "map": "NEW_BARK_TOWN", "x": 5, "y": 6,
                   "px": 80, "py": 96, "facing": "down", "moving": False}
        payload.update(fields)
        return self.post("sync_pos", **payload)

    def assertError(self, res, code):
        self.assertIs(res.get("success"), False, res)
        self.assertEqual(res.get("error"), code, res)


class TransportTests(ServerTest):
    def test_server_info_is_never_version_gated(self):
        res = self.get("/server/info", version=None)
        self.assertEqual(res, {"success": True, "version": VERSION, "modVersion": VERSION,
                               "generation": None})
        res = self.get("/server/info", version="0.1.0")
        self.assertTrue(res["success"])

    def test_version_gate_matches_major_minor(self):
        for ok in ("0.5.0", "0.5.1", "0.5.9", "0.5.1.3"):
            self.assertTrue(self.post("get_quests", version=ok)["success"], ok)
            self.assertTrue(self.get("/chat/history", version=ok)["success"], ok)
        for bad in ("0.4.0", "0.6.0", "1.5.1", "0.3.5.59", None):
            res = self.post("get_quests", version=bad)
            self.assertError(res, "VERSION_MISMATCH")
            self.assertEqual(res["serverVersion"], VERSION)
            self.assertError(self.get("/chat/history", version=bad), "VERSION_MISMATCH")

    def test_header_version_is_enough(self):
        body = json.dumps({"action": "get_quests"}).encode()
        res = self.request("POST", "/gts", body, {"X-Mod-Version": "0.5.0"})
        self.assertTrue(res["success"])

    def test_errors_are_http_200_json(self):
        self.assertError(self.post("no_such_action"), "UNKNOWN_ACTION")
        self.assertError(self.get("/no/such/path"), "NOT_FOUND")
        self.assertError(self.request("POST", "/gts", b"{not json",
                                      {"X-Mod-Version": VERSION}), "BAD_JSON")
        self.assertError(self.request("POST", "/elsewhere", b"{}",
                                      {"X-Mod-Version": VERSION}), "NOT_FOUND")
        self.assertError(self.post("login_player", trainerId="123456", token="ABCDEF12"),
                         "INVALID_LOGIN")

    def test_doubled_slashes_still_reach_the_api(self):
        # a server_url with a trailing slash makes the client post to //gts
        body = json.dumps({"action": "get_quests", "modVersion": VERSION}).encode()
        self.assertTrue(self.request("POST", "//gts", body)["success"])
        self.assertTrue(self.request("GET", "//server/info")["success"])

    def test_keep_alive_reuses_one_connection(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            body = json.dumps({"action": "get_quests", "modVersion": VERSION}).encode()
            sock = None
            for _ in range(5):
                conn.request("POST", "/gts", body=body, headers={
                    "Connection": "keep-alive", "Content-Type": "application/json"})
                res = conn.getresponse()
                data = res.read()
                self.assertEqual(res.status, 200)
                self.assertEqual(res.version, 11)
                self.assertEqual(int(res.getheader("Content-Length")), len(data))
                self.assertIsNone(res.getheader("Connection"))
                self.assertTrue(json.loads(data)["success"])
                if sock is None:
                    sock = conn.sock
                self.assertIs(conn.sock, sock, "the connection was kept open")
        finally:
            conn.close()

    def raw(self, request_bytes):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            s.sendall(request_bytes)
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
        finally:
            s.close()
        head, _, body = b"".join(chunks).partition(b"\r\n\r\n")
        return head.decode(), body

    def test_connection_close_is_answered_then_closed(self):
        # the client's raw-TCP fallback: Connection: close, then read to EOF
        body = json.dumps({"action": "get_quests", "modVersion": VERSION}).encode()
        head, data = self.raw(
            b"POST /gts HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
            b"Content-Type: application/json\r\nContent-Length: %d\r\n"
            b"X-Mod-Version: 0.5.1\r\n\r\n%s" % (len(body), body))
        self.assertTrue(head.startswith("HTTP/1.1 200"))
        self.assertIn("Connection: close", head)
        self.assertEqual(json.loads(data), {"success": True, "quests": []})

    def test_chunked_request_body(self):
        body = json.dumps({"action": "get_quests", "modVersion": VERSION}).encode()
        chunked = b"%x\r\n%s\r\n0\r\n\r\n" % (len(body), body)
        head, data = self.raw(
            b"POST /gts HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n" + chunked)
        self.assertTrue(head.startswith("HTTP/1.1 200"))
        self.assertTrue(json.loads(data)["success"])

    def test_concurrent_writers_and_readers(self):
        # answers are copied under the lock, so serializing one never races a write
        errors = []

        def worker(n):
            try:
                for i in range(15):
                    tid = str(600000 + n)
                    res = self.post("deposit", trainerId=tid, trainerName="W", offeredMon=mon("ABRA", i + 1),
                                    wanted=[]) if i < 10 else self.get("/gts/browse")
                    self.sync(tid, session="w%d" % n, x=i)
                    if not res.get("success"):
                        errors.append(res)
            except Exception as err:   # noqa: BLE001 - surfaced below
                errors.append(repr(err))

        threads = [threading.Thread(target=worker, args=(n,)) for n in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(30)
        self.assertEqual(errors, [])
        self.assertEqual(len(self.get("/gts/browse")["listings"]), 80)

    def test_non_ascii_text_round_trips_byte_exact(self):
        # the client sends raw UTF-8 (and the mod's own é); it gets the same bytes back
        tid = self.register("ETHAN")["trainerId"]
        res = self.post("send_chat", trainerId=tid, name="ETHAN", text="POKéMON ♂ ok", scope="global")
        self.assertEqual(res["message"]["text"], "POKéMON ♂ ok")
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/chat/history?version=0.5.1")
        raw = conn.getresponse().read()
        conn.close()
        self.assertIn("POKéMON ♂ ok".encode("utf-8"), raw)


class AccountTests(ServerTest):
    def test_register_gives_six_digit_id_and_hex_token(self):
        acc = self.register("ETHAN")
        self.assertRegex(acc["trainerId"], r"^\d{6}$")
        self.assertTrue(100001 <= int(acc["trainerId"]) <= 999999)
        self.assertRegex(acc["token"], r"^[0-9A-F]{8}$")
        for key in ("name", "level", "xp", "spriteId", "title", "favoriteMon"):
            self.assertIn(key, acc)
        self.assertEqual((acc["name"], acc["level"], acc["xp"]), ("ETHAN", 1, 0))
        other = self.register("LYRA")
        self.assertNotEqual(other["trainerId"], acc["trainerId"])
        self.assertNotEqual(other["token"], acc["token"])

    def test_names_are_unique_case_insensitively(self):
        self.register("Ethan")
        self.assertError(self.post("register_player", name="ETHAN"), "NAME_TAKEN")
        self.assertError(self.post("register_player", name="  "), "BAD_NAME")
        self.assertEqual(self.get("/player/check_name?name=ethan"), {"success": True, "taken": True})
        self.assertEqual(self.get("/player/check_name?name=GOLD"), {"success": True, "taken": False})
        self.register("MR.X")
        self.assertTrue(self.get("/player/check_name?name=" + quote("mr.x", safe=""))["taken"])

    def test_login_needs_the_matching_token_in_any_case(self):
        acc = self.register("ETHAN")
        res = self.post("login_player", trainerId=acc["trainerId"], token=acc["token"].lower())
        self.assertTrue(res["success"])
        self.assertEqual(res["account"]["trainerId"], acc["trainerId"])
        self.assertEqual(res["account"]["token"], acc["token"])
        self.assertError(self.post("login_player", trainerId=acc["trainerId"], token="00000000"),
                         "INVALID_LOGIN")
        self.assertError(self.post("login_player", trainerId="999999", token=acc["token"]),
                         "INVALID_LOGIN")
        # numeric ids (as the client sometimes sends them) work too
        res = self.post("login_player", trainerId=int(acc["trainerId"]), token=acc["token"])
        self.assertTrue(res["success"])

    def test_redeem_token(self):
        acc = self.register("ETHAN")
        res = self.post("redeem_token", token=" " + acc["token"].lower())
        self.assertTrue(res["success"])
        self.assertEqual(res["account"]["name"], "ETHAN")
        self.assertError(self.post("redeem_token", token="FFFFFFFF"), "TOKEN_NOT_FOUND")
        self.assertError(self.post("redeem_token", token=""), "TOKEN_NOT_FOUND")

    def test_update_profile_and_profile(self):
        acc = self.register("ETHAN")
        tid = acc["trainerId"]
        res = self.post("update_profile", trainerId=tid, token=acc["token"], name="ETHAN",
                        title="BIRD KEEPER", spriteId="SPRITE_RED", badges=3, pokedexCount=40,
                        pvpWins=1, blackouts=2, favoriteMon="TOGEPI")
        self.assertTrue(res["success"])
        profile = self.get("/gts/profile?trainerId=" + tid)["profile"]
        self.assertEqual(profile["title"], "BIRD KEEPER")
        self.assertEqual(profile["favoriteMon"], "TOGEPI")
        self.assertEqual((profile["badges"], profile["pokedexCount"], profile["blackouts"]), (3, 40, 2))
        self.assertEqual(profile["pvpWins"], 0, "update_profile's pvpWins delta is not a win")
        for key in ("name", "level", "xp", "pvpWins", "pvpLosses", "gtsTrades", "serverRank",
                    "totalPlayers", "rank", "badges", "pokedexCount", "favoriteMon"):
            self.assertIn(key, profile)
        self.assertEqual(profile["rank"], "NOVICE")
        self.assertError(self.post("update_profile", trainerId=tid, token="BADBAD00", title="X"),
                         "INVALID_TOKEN")
        self.assertError(self.post("update_profile", trainerId="111111"), "UNKNOWN_TRAINER")
        self.assertError(self.get("/gts/profile?trainerId=111111"), "UNKNOWN_TRAINER")

    def test_update_profile_never_steals_a_name(self):
        a = self.register("ETHAN")
        self.register("LYRA")
        self.post("update_profile", trainerId=a["trainerId"], name="lyra", title="X")
        self.assertEqual(self.get("/gts/profile?trainerId=" + a["trainerId"])["profile"]["name"], "ETHAN")

    def test_server_rank(self):
        a, b, c = self.register("A"), self.register("B"), self.register("C")
        self.post("sync_xp", trainerId=b["trainerId"], xpType="catch", xp=500)
        self.post("sync_xp", trainerId=c["trainerId"], xpType="catch", xp=100)
        ranks = {acc["name"]: self.get("/gts/profile?trainerId=" + acc["trainerId"])["profile"]
                 for acc in (a, b, c)}
        self.assertEqual(ranks["B"]["serverRank"], 1)
        self.assertEqual(ranks["C"]["serverRank"], 2)
        self.assertEqual(ranks["A"]["serverRank"], 3)
        self.assertEqual(ranks["A"]["totalPlayers"], 3)

    def test_rank_titles(self):
        expected = {1: "NOVICE", 10: "ROOKIE", 19: "ROOKIE", 20: "TRAINER", 30: "EXPERT",
                    40: "ACE TRAINER", 50: "MASTER", 60: "VETERAN", 70: "ELITE FOUR",
                    80: "CHAMPION", 90: "GRAND MASTER", 100: "POKéMON LEGEND"}
        for level, title in expected.items():
            self.assertEqual(gts_server.rank_title(level), title)


class XpTests(ServerTest):
    def test_level_curve_matches_the_client(self):
        self.assertEqual(gts_server.xp_for_level(1), 0)
        self.assertEqual(gts_server.xp_for_level(2), 50)
        self.assertEqual(gts_server.xp_for_level(3), int(50 * 2 ** 1.8))
        for level in range(1, 101):
            need = gts_server.xp_for_level(level)
            self.assertEqual(gts_server.level_for_xp(need), level)
            if level > 1:
                self.assertEqual(gts_server.level_for_xp(need - 1), level - 1)
        self.assertEqual(gts_server.level_for_xp(10 ** 9), 100)

    def test_sync_xp_adds_the_clients_delta(self):
        acc = self.register("ETHAN")
        tid = acc["trainerId"]
        res = self.post("sync_xp", trainerId=tid, token=acc["token"], xpType="gts_trade", xp=100,
                        badges=1, pokedexCount=5)
        self.assertEqual(res, {"success": True, "level": 2, "xp": 100, "leveledUp": True})
        res = self.post("sync_xp", trainerId=tid, xpType="catch", xp=50)
        self.assertEqual((res["xp"], res["leveledUp"]), (150, False))
        res = self.post("sync_xp", trainerId=tid, xpType="catch", xp=99999)
        self.assertEqual(res["xp"], 650, "delta clamped to 500")
        res = self.post("sync_xp", trainerId=tid, xpType="catch", xp=-40)
        self.assertEqual(res["xp"], 650, "negative delta clamped to 0")
        profile = self.get("/gts/profile?trainerId=" + tid)["profile"]
        self.assertEqual((profile["badges"], profile["pokedexCount"]), (1, 5))

    def test_sync_xp_falls_back_to_the_table(self):
        tid = self.register("ETHAN")["trainerId"]
        total = 0
        for xp_type, amount in sorted(gts_server.XP_TABLE.items()):
            total += amount
            self.assertEqual(self.post("sync_xp", trainerId=tid, xpType=xp_type)["xp"], total)
        total += 10
        self.assertEqual(self.post("sync_xp", trainerId=tid, xpType="something_new")["xp"], total)
        self.assertEqual(gts_server.XP_TABLE["wonder_trade"], 75)
        self.assertEqual(gts_server.XP_TABLE["pvp_win"], 100)

    def test_pvp_and_battle_counters(self):
        a = self.register("ETHAN")
        b = self.register("LYRA")
        tid = a["trainerId"]
        self.post("sync_xp", trainerId=tid, token=a["token"], xpType="pvp_win", xp=100,
                  opponentName="LYRA", opponentId=b["trainerId"])
        # the client follows a win with update_profile pvpWins = 1: still one win
        self.post("update_profile", trainerId=tid, token=a["token"], pvpWins=1)
        self.post("sync_xp", trainerId=b["trainerId"], xpType="pvp_loss", xp=25,
                  opponentName="ETHAN", opponentId=tid)
        self.post("sync_xp", trainerId=tid, xpType="wild_battle", xp=15)
        self.post("sync_xp", trainerId=tid, xpType="trainer_battle", xp=40)
        self.post("sync_xp", trainerId=tid, xpType="trainer_battle", xp=40)
        pa = self.get("/gts/profile?trainerId=" + tid)["profile"]
        pb = self.get("/gts/profile?trainerId=" + b["trainerId"])["profile"]
        self.assertEqual((pa["pvpWins"], pa["pvpLosses"]), (1, 0))
        self.assertEqual((pb["pvpWins"], pb["pvpLosses"]), (0, 1))
        account = self.store.data["accounts"][tid]
        self.assertEqual((account["wildBattles"], account["trainerBattles"]), (1, 2))
        history = self.get("/gts/browse")["history"]
        self.assertEqual(history[0]["text"], "ETHAN DEFEATED LYRA IN PVP!")

    def test_sync_xp_needs_an_account(self):
        self.assertError(self.post("sync_xp", trainerId="123456", xpType="catch"), "UNKNOWN_TRAINER")

    def test_report_battle_stat_and_quests(self):
        tid = self.register("ETHAN")["trainerId"]
        self.assertEqual(self.post("report_battle_stat", trainerId=tid, battleType="wild",
                                   species="RATTATA", caught=True), {"success": True})
        self.assertEqual(self.post("get_quests", trainerId=tid), {"success": True, "quests": []})
        self.assertEqual(self.store.data["accounts"][tid]["catches"], 0,
                         "battle stats are counted by sync_xp only")


class PresenceTests(ServerTest):
    def test_players_on_the_same_map_exclude_the_requester(self):
        self.sync("100001", session="a")
        self.sync("100002", session="b", x=7)
        self.sync("100003", session="c", map="ROUTE_29")
        res = self.sync("100001", session="a")
        self.assertTrue(res["success"])
        ids = [p["trainerId"] for p in res["players"]]
        self.assertEqual(ids, ["100002"])
        entry = res["players"][0]
        self.assertNotIn("sessionId", entry)
        self.assertEqual((entry["x"], entry["name"], entry["map"]), (7, "P100002", "NEW_BARK_TOWN"))
        self.assertIn("timestamp", entry)
        for key in ("serverHour", "serverMinute", "serverWeekday"):
            self.assertIsInstance(res[key], int)
        self.assertTrue(0 <= res["serverWeekday"] <= 6)
        self.assertEqual(res["partyXp"], [])
        self.assertIsNone(res["challenge"])
        self.assertIsNone(res["party"])
        self.assertIsNone(res["partyInvite"])

    def test_map_compare_ignores_case_and_caps_at_16(self):
        for i in range(20):
            self.sync(str(200000 + i), session="s%d" % i)
        res = self.sync("100001", session="me", map="new_bark_town")
        self.assertEqual(len(res["players"]), 16)

    def test_omitted_fields_keep_their_last_value(self):
        self.sync("100002", session="b", spriteId="SPRITE_LANCE", level=12)
        # the waiting-for-challenge sync leaves out spriteId and level
        self.post("sync_pos", trainerId="100002", sessionId="b", map="NEW_BARK_TOWN", x=9, y=9)
        entry = self.sync("100001", session="a")["players"][0]
        self.assertEqual((entry["spriteId"], entry["level"], entry["x"]), ("SPRITE_LANCE", 12, 9))

    def test_already_logged_in_only_while_the_other_session_is_live(self):
        self.sync("100001", session="first")
        self.assertError(self.sync("100001", session="second"), "ALREADY_LOGGED_IN")
        self.assertTrue(self.sync("100001", session="first")["success"])
        # a sync without a session id (the client's first one) never conflicts
        self.assertTrue(self.post("sync_pos", trainerId="100001", map="X")["success"])
        self.clock.advance(11)
        self.assertTrue(self.sync("100001", session="second")["success"], "crashed client reconnects")
        self.assertError(self.sync("100001", session="first"), "ALREADY_LOGGED_IN")

    def test_players_drop_after_30s_and_on_logout(self):
        self.sync("100001", session="a")
        self.sync("100002", session="b")
        players = self.get("/gts/players")["players"]
        self.assertEqual(set(players), {"100001", "100002"})
        self.assertEqual(players["100002"]["name"], "P100002")
        self.assertNotIn("sessionId", players["100002"])
        self.clock.advance(20)
        self.sync("100001", session="a")
        self.clock.advance(15)
        self.assertEqual(set(self.get("/gts/players")["players"]), {"100001"})
        self.assertEqual(self.post("logout", trainerId="100001"), {"success": True})
        self.assertEqual(self.get("/gts/players")["players"], {})


class ChatTests(ServerTest):
    def test_ids_keep_increasing_past_the_trim(self):
        last = 0
        for i in range(120):
            msg = self.post("send_chat", trainerId="777777", name="BUDDY", text="M%d" % i,
                            scope="global")["message"]
            self.assertGreater(msg["id"], last)
            last = msg["id"]
        messages = self.get("/chat/history")["messages"]
        self.assertEqual(len(messages), 50)
        ids = [m["id"] for m in messages]
        self.assertEqual(ids, sorted(ids))
        self.assertEqual(ids[-1], last)
        self.assertEqual(messages[-1]["text"], "M119")
        self.assertEqual(len(self.store.data["chat"]), 100)
        for key in ("id", "trainerId", "name", "text", "scope", "time"):
            self.assertIn(key, messages[0])

    def test_text_is_trimmed_and_empty_refused(self):
        msg = self.post("send_chat", trainerId="1", name="A", text="x" * 300, scope="global")["message"]
        self.assertEqual(len(msg["text"]), 200)
        self.assertError(self.post("send_chat", trainerId="1", name="A", text="   "), "EMPTY_MESSAGE")


class ChallengeTests(ServerTest):
    def test_challenge_rides_every_sync_until_cleared(self):
        party = [mon("CHIKORITA")]
        res = self.post("send_challenge", targetId="100002", fromId="100001", fromName="ETHAN",
                        challengeType="PVP", party=party, seed=4242, roomId="ROOM_1_2_L2")
        self.assertTrue(res["success"])
        for _ in range(3):
            ch = self.sync("100002", session="b")["challenge"]
            self.assertEqual(ch, {"fromId": "100001", "fromName": "ETHAN", "type": "PVP",
                                  "party": party, "seed": 4242, "roomId": "ROOM_1_2_L2"})
        self.assertIsNone(self.sync("100001", session="a")["challenge"])
        self.post("clear_challenge", trainerId="100002")
        self.assertIsNone(self.sync("100002", session="b")["challenge"])

    def test_room_id_is_relayed_verbatim_and_challenges_expire(self):
        self.post("send_challenge", targetId="100001", fromId="100002", fromName="LYRA",
                  challengeType="ACCEPT_PVP", seed=1, roomId="ROOM_1_2_L2K", party=[mon("TOTODILE")])
        self.assertEqual(self.sync("100001", session="a")["challenge"]["roomId"], "ROOM_1_2_L2K")
        self.clock.advance(16)
        self.assertIsNone(self.sync("100001", session="a")["challenge"])

    def test_bad_challenges_are_refused(self):
        self.assertError(self.post("send_challenge", targetId="1", fromId="2", challengeType="DUEL"),
                         "BAD_REQUEST")
        self.assertError(self.post("send_challenge", fromId="2", challengeType="PVP"), "BAD_REQUEST")
        res = self.post("send_challenge", targetId="1", fromId="2", fromName="X", challengeType="DECLINE")
        self.assertTrue(res["success"])

    def test_battle_room_inboxes(self):
        room = "ROOM_100001_100002_L2K"
        for i in range(3):
            self.post("send_battle_msg", roomId=room, targetId="100002",
                      msg={"type": "action", "turn": i, "move": {"slot": 2}})
        self.post("send_battle_msg", roomId=room, targetId="100001", msg={"type": "hash", "h": "ab"})
        res = self.post("poll_battle_msgs", roomId=room, myId="100002")
        self.assertEqual([m["turn"] for m in res["msgs"]], [0, 1, 2])
        self.assertEqual(res["msgs"][0]["move"], {"slot": 2})
        self.assertEqual(self.post("poll_battle_msgs", roomId=room, myId="100002")["msgs"], [])
        self.assertEqual(self.post("poll_battle_msgs", roomId=room, myId="100001")["msgs"],
                         [{"type": "hash", "h": "ab"}])
        self.post("send_battle_msg", roomId=room, targetId="100001", msg={"type": "bye"})
        self.assertEqual(self.post("clear_battle_room", roomId=room), {"success": True})
        self.assertEqual(self.post("poll_battle_msgs", roomId=room, myId="100001")["msgs"], [])
        self.assertEqual(self.post("poll_battle_msgs", roomId="nope", myId="1"),
                         {"success": True, "msgs": []})


class GtsTests(ServerTest):
    def deposit(self, tid, name, m, wanted=None):
        return self.post("deposit", trainerId=tid, trainerName=name, offeredMon=m,
                         wanted=wanted if wanted is not None else ["KADABRA"])

    def test_deposit_browse_trade_claim(self):
        seller = self.register("SELLER")
        buyer = self.register("BUYER")
        offered = mon("ABRA", 16, item="TWISTEDSPOON", happiness=70,
                      extra={"nested": [1, 2, {"deep": "é"}]})
        res = self.deposit(seller["trainerId"], "SELLER", offered)
        self.assertTrue(res["success"])
        listing = res["listing"]
        self.assertRegex(listing["id"], r"^GTS_\d+$")
        self.assertEqual(listing["offeredMon"], offered)
        self.assertEqual(listing["wanted"], ["KADABRA"])
        browse = self.get("/gts/browse")
        self.assertEqual(browse["listings"], {listing["id"]: listing})
        self.assertEqual(browse["history"][0]["text"], "SELLER DEPOSITED ABRA")

        self.assertError(self.post("trade", listingId=listing["id"], buyerId=buyer["trainerId"],
                                   buyerName="BUYER", sentMon=mon("PIDGEY")), "NOT_WANTED")
        self.assertError(self.post("trade", listingId=listing["id"], buyerId=seller["trainerId"],
                                   buyerName="SELLER", sentMon=mon("KADABRA")), "OWN_LISTING")
        sent = mon("KADABRA", 20)
        res = self.post("trade", listingId=listing["id"], buyerId=buyer["trainerId"],
                        buyerName="BUYER", sentMon=sent)
        self.assertEqual(res, {"success": True, "receivedMon": offered})
        self.assertEqual(self.get("/gts/browse")["listings"], {})
        self.assertError(self.post("trade", listingId=listing["id"], buyerId=buyer["trainerId"],
                                   buyerName="BUYER", sentMon=sent), "LISTING_GONE")
        for acc in (seller, buyer):
            self.assertEqual(self.get("/gts/profile?trainerId=" + acc["trainerId"])
                             ["profile"]["gtsTrades"], 1)
        self.assertEqual(self.get("/gts/browse")["history"][0]["text"],
                         "BUYER TRADED KADABRA TO SELLER FOR ABRA")

        claims = self.get("/gts/claims?trainerId=" + seller["trainerId"])["claims"]
        self.assertEqual(len(claims), 1)
        claim = claims[0]
        self.assertEqual((claim["mon"], claim["fromName"], claim["fromId"], claim["originalOffered"]),
                         (sent, "BUYER", buyer["trainerId"], "ABRA"))
        self.assertIn("timestamp", claim)
        self.assertEqual(self.get("/gts/claims?trainerId=" + buyer["trainerId"])["claims"], [])
        res = self.post("claim", trainerId=seller["trainerId"], index=0)
        self.assertTrue(res["success"])
        self.assertEqual(res["claimed"]["mon"], sent)
        self.assertError(self.post("claim", trainerId=seller["trainerId"], index=0), "NO_CLAIM")

    def test_claim_by_id(self):
        s = self.register("SELLER")["trainerId"]
        for species in ("ABRA", "GASTLY", "MACHOP"):
            lid = self.deposit(s, "SELLER", mon(species), wanted=[])["listing"]["id"]
            self.post("trade", listingId=lid, buyerId="200000", buyerName="B", sentMon=mon("RATTATA" + species))
        claims = self.get("/gts/claims?trainerId=" + s)["claims"]
        ids = [c["id"] for c in claims]
        res = self.post("claim", trainerId=s, index=0, claimId=ids[1])
        self.assertEqual(res["claimed"]["mon"]["species"], "RATTATAGASTLY")
        self.assertError(self.post("claim", trainerId=s, index=0, claimId=ids[1]), "NO_CLAIM")
        self.assertEqual([c["id"] for c in self.get("/gts/claims?trainerId=" + s)["claims"]],
                         [ids[0], ids[2]])

    def test_withdraw_only_your_own_and_only_once(self):
        s = self.register("SELLER")["trainerId"]
        b = self.register("BUYER")["trainerId"]
        listing = self.deposit(s, "SELLER", mon("ABRA"), wanted=[])["listing"]
        self.assertError(self.post("withdraw", listingId=listing["id"], trainerId=b), "NOT_YOUR_LISTING")
        res = self.post("withdraw", listingId=listing["id"], trainerId=s)
        self.assertEqual(res, {"success": True, "mon": listing["offeredMon"]})
        self.assertError(self.post("withdraw", listingId=listing["id"], trainerId=s), "LISTING_GONE")

    def test_withdraw_after_a_trade_fails(self):
        # the race the client used to lose: the mon must not come back twice
        s = self.register("SELLER")["trainerId"]
        listing = self.deposit(s, "SELLER", mon("ABRA"), wanted=[])["listing"]
        self.post("trade", listingId=listing["id"], buyerId="300000", buyerName="B", sentMon=mon("ZUBAT"))
        self.assertError(self.post("withdraw", listingId=listing["id"], trainerId=s), "LISTING_GONE")

    def test_ten_listings_per_trainer(self):
        s = self.register("SELLER")["trainerId"]
        for i in range(10):
            self.assertTrue(self.deposit(s, "SELLER", mon("ABRA", i + 1))["success"])
        self.assertError(self.deposit(s, "SELLER", mon("ABRA")), "LISTING_LIMIT")
        self.assertTrue(self.deposit("400000", "OTHER", mon("ABRA"))["success"])

    def test_bad_mons_are_refused(self):
        self.assertError(self.deposit("1", "A", "PIKACHU"), "BAD_MON")
        self.assertError(self.deposit("1", "A", {}), "BAD_MON")
        lid = self.deposit("1", "A", mon("ABRA"), wanted=[])["listing"]["id"]
        self.assertError(self.post("trade", listingId=lid, buyerId="2", sentMon=None), "BAD_MON")

    def test_listings_expire_back_to_their_owner_and_claims_expire(self):
        s = self.register("SELLER")["trainerId"]
        offered = mon("ABRA")
        self.deposit(s, "SELLER", offered)
        self.clock.advance(31 * 86400)
        self.assertEqual(self.get("/gts/browse")["listings"], {})
        claims = self.get("/gts/claims?trainerId=" + s)["claims"]
        self.assertEqual(len(claims), 1)
        self.assertEqual(claims[0]["mon"], offered)
        self.clock.advance(61 * 86400)
        self.assertEqual(self.get("/gts/claims?trainerId=" + s)["claims"], [])


class WonderTradeTests(ServerTest):
    def test_pool_withdraw_match_and_claim(self):
        status = self.post("wonder_trade_status", trainerId="1")
        self.assertEqual(status, {"success": True, "poolCount": 0, "threshold": 5,
                                  "mine": None, "claim": None})
        first = mon("SENTRET")
        res = self.post("wonder_trade_deposit", trainerId="1", trainerName="T1", offeredMon=first)
        self.assertEqual(res, {"success": True, "poolCount": 1, "matched": False})
        status = self.post("wonder_trade_status", trainerId="1")
        self.assertEqual(status["mine"]["offeredMon"], first)
        self.assertError(self.post("wonder_trade_deposit", trainerId="1", trainerName="T1",
                                   offeredMon=mon("PIDGEY")), "ALREADY_IN_POOL")
        self.assertEqual(self.post("wonder_trade_withdraw", trainerId="1"), {"success": True, "mon": first})
        self.assertError(self.post("wonder_trade_withdraw", trainerId="1"), "NOT_IN_POOL")
        self.assertEqual(self.post("wonder_trade_status", trainerId="2")["poolCount"], 0)

        mons = {}
        for i in range(1, 6):
            mons[str(i)] = mon("MON%d" % i)
            res = self.post("wonder_trade_deposit", trainerId=str(i), trainerName="T%d" % i,
                            offeredMon=mons[str(i)])
            self.assertEqual(res["matched"], i == 5)
            self.assertEqual(res["poolCount"], i % 5)
        received = {}
        for i in range(1, 6):
            claim = self.post("wonder_trade_status", trainerId=str(i))["claim"]
            self.assertIsNotNone(claim)
            self.assertNotEqual(claim["fromId"], str(i), "nobody gets their own")
            self.assertEqual(claim["mon"], mons[claim["fromId"]])
            self.assertEqual(claim["fromName"], "T" + claim["fromId"])
            self.assertEqual(claim["sentMon"], mons[str(i)])
            received[str(i)] = claim["fromId"]
        self.assertEqual(sorted(received.values()), ["1", "2", "3", "4", "5"])

        self.assertError(self.post("wonder_trade_withdraw", trainerId="3"), "NOT_IN_POOL")
        self.assertError(self.post("wonder_trade_deposit", trainerId="3", trainerName="T3",
                                   offeredMon=mon("X")), "CLAIM_PENDING")
        res = self.post("wonder_trade_claim", trainerId="3")
        self.assertTrue(res["success"])
        self.assertEqual(res["claim"]["mon"], mons[received["3"]])
        self.assertError(self.post("wonder_trade_claim", trainerId="3"), "NO_CLAIM")
        self.assertIsNone(self.post("wonder_trade_status", trainerId="3")["claim"])
        self.assertTrue(self.post("wonder_trade_deposit", trainerId="3", trainerName="T3",
                                  offeredMon=mon("X"))["success"])
        self.assertEqual(self.get("/gts/browse")["history"][0]["text"], "WONDER TRADE MATCHED 5 TRAINERS!")

    def test_matching_is_always_a_derangement(self):
        for round_ in range(20):
            self.store.data["wonderPool"] = []
            self.store.data["wonderClaims"] = {}
            for i in range(5):
                self.post("wonder_trade_deposit", trainerId="%d-%d" % (round_, i), trainerName="T",
                          offeredMon=mon("M%d" % i))
            for tid, claim in self.store.data["wonderClaims"].items():
                self.assertNotEqual(claim["fromId"], tid)
            self.assertEqual(len(self.store.data["wonderClaims"]), 5)


class PartyTests(ServerTest):
    def test_create_invite_accept_warp_leave(self):
        self.sync("100001", session="a", name="ETHAN", level=3)
        self.sync("100002", session="b", name="LYRA", x=11, y=4, map="ROUTE_29")
        res = self.post("party_create", trainerId="100001", name="ETHAN", level=3, map="NEW_BARK_TOWN")
        self.assertEqual(res["party"], {"leaderId": "100001",
                                        "members": {"100001": {"name": "ETHAN", "level": 3,
                                                               "map": "NEW_BARK_TOWN"}}})
        self.assertTrue(self.post("party_invite", trainerId="100001", name="ETHAN",
                                  targetId="100002")["success"])
        invite = self.sync("100002", session="b", map="ROUTE_29", x=11, y=4)["partyInvite"]
        self.assertEqual(invite["fromId"], "100001")
        self.assertEqual(invite["fromName"], "ETHAN")
        res = self.post("party_accept", trainerId="100002", name="LYRA", level=8, map="ROUTE_29")
        self.assertTrue(res["success"])
        self.assertEqual(set(res["party"]["members"]), {"100001", "100002"})
        synced = self.sync("100002", session="b", map="ROUTE_29", x=11, y=4)
        self.assertIsNone(synced["partyInvite"])
        self.assertEqual(synced["party"]["leaderId"], "100001")
        self.assertEqual(self.sync("100001", session="a")["party"]["members"]["100002"]["map"], "ROUTE_29")
        self.assertEqual(self.post("party_warp_target", targetId="100002"),
                         {"success": True, "map": "ROUTE_29", "x": 11, "y": 4})
        self.assertError(self.post("party_warp_target", targetId="999999"), "NOT_ONLINE")
        self.post("party_leave", trainerId="100001")
        party = self.sync("100002", session="b", map="ROUTE_29")["party"]
        self.assertEqual(party["leaderId"], "100002")
        self.assertEqual(set(party["members"]), {"100002"})
        self.assertIsNone(self.sync("100001", session="a")["party"])

    def test_invite_without_a_party_creates_one(self):
        self.assertTrue(self.post("party_invite", trainerId="1", name="A", targetId="2")["success"])
        self.assertEqual(self.sync("1", session="a")["party"]["leaderId"], "1")

    def test_decline_expiry_and_full_party(self):
        self.post("party_invite", trainerId="1", name="A", targetId="2")
        self.post("party_decline", trainerId="2")
        self.assertIsNone(self.sync("2", session="b")["partyInvite"])
        self.assertError(self.post("party_accept", trainerId="2"), "NO_INVITE")
        self.post("party_invite", trainerId="1", name="A", targetId="2")
        self.clock.advance(31)
        self.assertIsNone(self.sync("2", session="b")["partyInvite"])
        self.assertError(self.post("party_accept", trainerId="2"), "NO_INVITE")
        for member in ("2", "3", "4"):
            self.post("party_invite", trainerId="1", name="A", targetId=member)
            self.assertTrue(self.post("party_accept", trainerId=member)["success"])
        self.assertError(self.post("party_invite", trainerId="1", name="A", targetId="5"), "PARTY_FULL")
        self.assertError(self.post("party_invite", trainerId="1", name="A", targetId="3"),
                         "ALREADY_IN_PARTY")

    def test_party_xp_is_never_invented(self):
        self.post("party_invite", trainerId="1", name="A", targetId="2")
        self.post("party_accept", trainerId="2")
        self.register("A")
        self.assertEqual(self.sync("2", session="b")["partyXp"], [])


class PersistenceTests(ServerTest):
    def test_state_survives_a_restart(self):
        acc = self.register("ETHAN")
        tid = acc["trainerId"]
        self.post("sync_xp", trainerId=tid, xpType="pvp_win", xp=100, opponentName="LYRA")
        listing = self.post("deposit", trainerId=tid, trainerName="ETHAN", offeredMon=mon("ABRA"),
                            wanted=[])["listing"]
        other = self.post("deposit", trainerId=tid, trainerName="ETHAN", offeredMon=mon("GASTLY"),
                          wanted=[])["listing"]
        self.post("trade", listingId=other["id"], buyerId="200000", buyerName="B", sentMon=mon("ZUBAT"))
        for i in range(3):
            self.post("send_chat", trainerId=tid, name="ETHAN", text="hi %d" % i, scope="global")
        self.post("wonder_trade_deposit", trainerId=tid, trainerName="ETHAN", offeredMon=mon("SENTRET"))
        self.sync(tid, session="a")
        self.post("party_create", trainerId=tid)
        self.post("send_challenge", targetId=tid, fromId="2", fromName="B", challengeType="PVP")

        self.restart()

        res = self.post("login_player", trainerId=tid, token=acc["token"])
        self.assertTrue(res["success"])
        self.assertEqual((res["account"]["xp"], res["account"]["level"], res["account"]["pvpWins"]),
                         (100, 2, 1))
        browse = self.get("/gts/browse")
        self.assertEqual(list(browse["listings"]), [listing["id"]])
        self.assertTrue(browse["history"])
        self.assertEqual(len(self.get("/gts/claims?trainerId=" + tid)["claims"]), 1)
        self.assertEqual([m["text"] for m in self.get("/chat/history")["messages"]],
                         ["hi 0", "hi 1", "hi 2"])
        msg = self.post("send_chat", trainerId=tid, name="ETHAN", text="after", scope="global")["message"]
        self.assertEqual(msg["id"], 4, "chat ids continue after a restart")
        new = self.post("deposit", trainerId=tid, trainerName="ETHAN", offeredMon=mon("ABRA"),
                        wanted=[])["listing"]
        self.assertGreater(int(new["id"][4:]), int(other["id"][4:]))
        self.assertEqual(self.post("wonder_trade_status", trainerId=tid)["poolCount"], 1)
        # presence, parties and challenges are memory only
        self.assertEqual(self.get("/gts/players")["players"], {})
        synced = self.sync(tid, session="new")
        self.assertIsNone(synced["party"])
        self.assertIsNone(synced["challenge"])

    def test_writes_are_atomic_files(self):
        self.register("ETHAN")
        with open(self.path, encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(len(data["accounts"]), 1)
        self.assertEqual([n for n in os.listdir(self.dir) if n != "data.json"], [])

    def test_a_corrupt_file_is_moved_aside(self):
        self.stop()
        with open(self.path, "w") as f:
            f.write("{ not json")
        warning = io.StringIO()
        with contextlib.redirect_stderr(warning):
            self.start()
        self.assertIn("unreadable", warning.getvalue())
        self.assertTrue(self.register("ETHAN"))
        self.assertTrue(any(n.startswith("data.json.broken-") for n in os.listdir(self.dir)))


class GenerationTests(ServerTest):
    def test_the_first_game_to_connect_claims_the_world(self):
        self.assertIsNone(self.get("/server/info")["generation"])
        # a request that names no game (a script) claims nothing
        self.assertTrue(self.post("get_quests", game="").get("success"))
        self.assertIsNone(self.get("/server/info")["generation"])
        # nor does a read
        self.assertTrue(self.get("/chat/history?gen=1")["success"])
        self.assertIsNone(self.get("/server/info")["generation"])
        self.assertTrue(self.post("register_player", name="RED", game="Pokemon Red")["success"])
        self.assertEqual(self.get("/server/info")["generation"], 1)
        for game in ("Pokemon Blue", "Pokemon Yellow"):
            self.assertTrue(self.post("get_quests", game=game)["success"], game)

    def test_the_other_generation_is_turned_away(self):
        self.post("register_player", name="RED", game="Pokemon Red")
        for game in ("Pokemon Crystal", "Pokemon Gold", "Pokemon FireRed", "Pokemon Emerald"):
            res = self.post("register_player", name="GOLD", game=game)
            self.assertError(res, "WRONG_GENERATION")
            self.assertEqual(res["serverGeneration"], 1)
        self.assertError(self.post("sync_pos", trainerId="1", sessionId="s", map="NEW_BARK_TOWN",
                                   game="Pokemon Crystal"), "WRONG_GENERATION")
        self.assertError(self.get("/gts/browse?gen=2"), "WRONG_GENERATION")
        self.assertTrue(self.get("/gts/browse?gen=1")["success"])
        self.assertTrue(self.get("/gts/browse")["success"], "a read that names no generation")
        self.assertEqual(self.get("/gts/players")["players"], {})

    def test_an_explicit_generation_wins_over_the_game_name(self):
        self.post("get_quests", game="Pokemon Crystal")
        self.assertEqual(self.get("/server/info")["generation"], 2)
        self.assertError(self.post("get_quests", game="Pokemon Crystal", generation=1),
                         "WRONG_GENERATION")
        self.assertTrue(self.post("get_quests", game="", generation=2)["success"])

    def test_gen_3_is_never_admitted(self):
        res = self.post("register_player", name="MAY", game="Pokemon Emerald")
        self.assertError(res, "WRONG_GENERATION")
        self.assertIsNone(res["serverGeneration"])
        self.assertIsNone(self.get("/server/info")["generation"])

    def test_the_generation_survives_a_restart(self):
        self.post("get_quests", game="Pokemon Yellow")
        self.restart()
        self.assertEqual(self.get("/server/info")["generation"], 1)
        self.assertError(self.post("get_quests", game="Pokemon Crystal"), "WRONG_GENERATION")

    def test_generation_of(self):
        cases = {("", "Pokemon Red"): 1, ("", "Pokemon Blue"): 1, ("", "Pokemon Yellow"): 1,
                 ("", "Pokemon Crystal"): 2, ("", "Pokemon Gold"): 2, ("", "Pokemon Silver"): 2,
                 ("", "Pokemon FireRed"): 3, ("", "Pokemon LeafGreen"): 3, ("", "Pokemon Emerald"): 3,
                 ("", ""): None, (None, None): None, (2, "Pokemon Red"): 2, ("1", None): 1,
                 ("7", "Pokemon Red"): 1}
        for (explicit, game), gen in cases.items():
            self.assertEqual(gts_server.generation_of(explicit, game), gen, (explicit, game))


class GenOneServerTests(ServerTest):
    generation = 1
    game = "Pokemon Red"

    def test_a_gen_1_server_from_the_start(self):
        self.assertEqual(self.get("/server/info")["generation"], 1)
        self.assertTrue(self.register("RED")["trainerId"])
        self.assertError(self.post("get_quests", game="Pokemon Crystal"), "WRONG_GENERATION")
        with open(self.path, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["generation"], 1)

    def test_gen_1_tokens_can_be_typed_on_the_gen_1_keyboard(self):
        # Red/Blue/Yellow's naming screen has letters and no digits
        for name in ("RED", "LEAF", "GARY"):
            token = self.register(name)["token"]
            self.assertRegex(token, r"^[A-Z]{8}$")
            res = self.post("redeem_token", token=token.lower())
            self.assertEqual(res["account"]["name"], name)

    def test_a_data_file_keeps_its_generation(self):
        self.stop()
        with self.assertRaises(ValueError) as caught:
            gts_server.GtsStore(self.path, generation=2)
        self.assertIn("different --data", str(caught.exception))
        self.start()

    def test_the_flag_rejects_other_generations(self):
        with self.assertRaises(ValueError):
            gts_server.GtsStore(os.path.join(self.dir, "other.json"), generation=3)


class CommandLineTests(unittest.TestCase):
    def test_defaults(self):
        self.assertEqual(gts_server.DEFAULT_PORT, 7779)
        self.assertEqual(gts_server.DEFAULT_VERSION, "0.5.1")
        self.assertEqual(gts_server.DEFAULT_DATA,
                         os.path.join(os.path.dirname(os.path.abspath(gts_server.__file__)),
                                      "gts_data.json"))

    def test_banner_lists_server_url_lines(self):
        store = gts_server.GtsStore(os.path.join(tempfile.mkdtemp(), "d.json"))
        text = gts_server.banner("0.0.0.0", 7779, store)
        self.assertIn("server_url=http://127.0.0.1:7779", text)
        self.assertIn("the first game to connect decides", text)
        store = gts_server.GtsStore(os.path.join(tempfile.mkdtemp(), "d.json"), generation=1)
        self.assertIn("World: Gen 1 (Red/Blue/Yellow)", gts_server.banner("127.0.0.1", 7779, store))

    def test_main_refuses_a_data_file_of_the_other_generation(self):
        path = os.path.join(tempfile.mkdtemp(), "d.json")
        gts_server.GtsStore(path, generation=2)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(gts_server.main(["--data", path, "--gen", "1", "--port", "0"]), 1)
        self.assertIn("Gen 2 (Crystal) world", err.getvalue())


if __name__ == "__main__":
    unittest.main()
