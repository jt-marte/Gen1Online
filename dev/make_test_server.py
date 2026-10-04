"""Derive a stand-in test server from the legacy gts_server.py (v0.3.5.59).

The 0.5.x server was never committed here.  This patches the legacy one just
enough to answer a 0.5.x Crystal client: version gate, game gate, the actions
added since, and the RTC fields the client reads off sync_pos.  Test-only;
Wonder Trade and quests are stubs.  Superseded once server/ is rewritten.

usage: make_test_server.py <legacy gts_server.py> <out.py>
"""
import sys

src_path, out_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding="utf-8").read()

def rep(old, new):
    global src
    assert src.count(old) == 1, "pattern not found: " + old[:60]
    src = src.replace(old, new)

rep('MOD_VERSION = "0.3.5.59"',
    'MOD_VERSION = os.environ.get("GTS_MOD_VERSION", "0.5.0")')
rep('if game_ver and "gold" not in game_ver and "gen2" not in game_ver:',
    'if game_ver and not any(k in game_ver for k in ("gold", "gen2", "crystal")):')
rep('''            self._send_json({
                "success": True,
                "players": map_players,''', '''            _lt = time.localtime()
            self._send_json({
                "success": True,
                "serverHour": _lt.tm_hour,
                "serverMinute": _lt.tm_min,
                "serverWeekday": (_lt.tm_wday + 1) % 7,
                "players": map_players,''')
rep('''        else:
            self._send_json({"error": "Unknown action"}, status=400)
''', '''        elif action == "login_player":
            tid = str(req.get("trainerId"))
            acc = db.get("accounts", {}).get(tid)
            if acc and acc.get("token") == req.get("token"):
                self._send_json({"success": True, "account": acc})
            else:
                self._send_json({"success": False, "error": "BAD_TOKEN"}, status=403)

        elif action == "logout":
            db.setdefault("active_players", {}).pop(str(req.get("trainerId")), None)
            self._send_json({"success": True})

        elif action == "get_quests":
            self._send_json({"success": True, "quests": []})

        elif action in ("wonder_trade_status", "wonder_trade_deposit",
                        "wonder_trade_withdraw", "wonder_trade_claim"):
            self._send_json({"success": True})

        else:
            self._send_json({"error": "Unknown action"}, status=400)
''')
open(out_path, "w", encoding="utf-8").write(src)
print("wrote", out_path)
