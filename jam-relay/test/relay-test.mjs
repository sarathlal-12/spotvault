// End-to-end check of the relay: node test/relay-test.mjs [baseUrl]
// Creates a room, connects a host and a guest, approves the guest, and checks
// state, requests and clock pings flow both ways.
const base = process.argv[2] ?? "http://localhost:5173";
const wsBase = base.replace(/^http/, "ws");
const fail = (m) => {
	console.error("FAIL:", m);
	process.exit(1);
};

function open(url) {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(url);
		const inbox = [];
		const waiters = [];
		ws.onmessage = (e) => {
			const m = JSON.parse(e.data);
			const w = waiters.findIndex((x) => x.test(m));
			if (w >= 0) waiters.splice(w, 1)[0].resolve(m);
			else inbox.push(m);
		};
		ws.next = (t, ms = 5000) =>
			new Promise((res, rej) => {
				const i = inbox.findIndex((m) => m.t === t);
				if (i >= 0) return res(inbox.splice(i, 1)[0]);
				const timer = setTimeout(() => rej(new Error(`timeout waiting for ${t}`)), ms);
				waiters.push({ test: (m) => m.t === t, resolve: (m) => (clearTimeout(timer), res(m)) });
			});
		ws.json = (m) => ws.send(JSON.stringify(m));
		ws.onopen = () => resolve(ws);
		ws.onerror = (e) => reject(e);
	});
}

const r = await fetch(`${base}/rooms`, { method: "POST" });
const { code, key } = await r.json();
if (!code || !key) fail("no room");
console.log("room", code);

const host = await open(`${wsBase}/rooms/${code}/ws?role=host&key=${key}&name=Host`);
await host.next("hello");

const badOk = await open(`${wsBase}/rooms/${code}/ws?role=host&key=wrong&name=X`).then(() => true, () => false);
if (badOk) fail("wrong host key was accepted");

const guest = await open(`${wsBase}/rooms/${code}/ws?role=guest&id=g1&name=Friend`);
await guest.next("waiting");
const req = await host.next("request");
if (req.id !== "g1" || req.name !== "Friend") fail("bad request");

host.json({ t: "state", song: { title: "Paper Planes" }, pos: 1234, playing: true });
host.json({ t: "approve", id: "g1", ok: true });
await guest.next("welcome");
const st = await guest.next("state");
if (st.song?.title !== "Paper Planes" || typeof st.s !== "number") fail("state not relayed");

guest.json({ t: "req", action: "add", song: { title: "X" } });
const fwd = await host.next("req");
if (fwd.from !== "g1" || fwd.action !== "add") fail("guest request not forwarded");

const c = Date.now();
guest.json({ t: "ping", c });
const pong = await guest.next("pong");
if (pong.c !== c || typeof pong.s !== "number") fail("bad pong");

const info = await (await fetch(`${base}/rooms/${code}`)).json();
if (!info.open || info.guests !== 1) fail(`bad info ${JSON.stringify(info)}`);

// A second guest gets turned away.
const g2 = await open(`${wsBase}/rooms/${code}/ws?role=guest&id=g2&name=Other`);
await g2.next("waiting");
await host.next("request");
host.json({ t: "approve", id: "g2", ok: false });
await g2.next("denied");

host.json({ t: "end" });
await guest.next("ended");
const after = await (await fetch(`${base}/rooms/${code}`)).json();
if (after.open) fail("room still open after end");

console.log("relay OK");
process.exit(0);
