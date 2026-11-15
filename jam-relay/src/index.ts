import { DurableObject } from "cloudflare:workers";

/**
 * SpotVault Internet Jam relay.
 *
 * One Durable Object per Jam room. The host and guests connect over
 * WebSockets; this relay only passes small messages along (what's playing,
 * where, play/pause, queue, join requests). No audio goes through here: each
 * guest's phone downloads the songs itself.
 *
 *   POST /rooms                       -> { code, key }   (host creates a room)
 *   GET  /rooms/:code                 -> { open, host }  (is the room there?)
 *   GET  /rooms/:code/ws?role=host&key=..&name=..        (host socket)
 *   GET  /rooms/:code/ws?role=guest&id=..&name=..        (guest socket)
 *
 * Messages (JSON):
 *   any   -> {t:"ping", c}            relay -> {t:"pong", c, s}   (clock sync)
 *   host  -> {t:"state", ...}         relay -> guests             (latest kept)
 *   host  -> {t:"approve", id, ok}    relay -> guest {t:"welcome"} / {t:"denied"}
 *   host  -> {t:"kick", id} | {t:"end"}
 *   host  -> {t:"to", id, msg}        relay -> that guest only
 *   guest -> {t:"req", ...}           relay -> host {t:"req", from, name, ...}
 *   relay -> host {t:"request", id, name}, {t:"guests", list}
 *   relay -> guest {t:"waiting"}, {t:"hostAway"}, {t:"ended"}
 */

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O, 1/I
const ROOM_TTL_MS = 6 * 60 * 60 * 1000; // a room closes 6 h after it goes quiet
const MAX_GUESTS = 30;

type Tag = { role: "host" | "guest"; id: string; name: string };

const json = (body: unknown, status = 200) =>
	new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
	});

function randomCode(n: number): string {
	const bytes = crypto.getRandomValues(new Uint8Array(n));
	return Array.from(bytes, (b) => ALPHABET[b % ALPHABET.length]).join("");
}

function clean(s: string | null, max = 40): string {
	return (s ?? "").replace(/[\u0000-\u001f]/g, "").trim().slice(0, max);
}

export class JamRoom extends DurableObject<Env> {
	/** Sets the host key for a new room. False when the code is taken. */
	async create(key: string): Promise<boolean> {
		if (await this.ctx.storage.get("key")) return false;
		await this.ctx.storage.put({ key, approved: [] as string[] });
		await this.touch();
		return true;
	}

	async info(): Promise<{ open: boolean; host: string; guests: number }> {
		const open = !!(await this.ctx.storage.get("key"));
		await this.approved();
		const host = this.sockets("host")[0];
		return { open, host: host ? this.tag(host).name : "", guests: this.approvedGuests().length };
	}

	private async touch() {
		await this.ctx.storage.setAlarm(Date.now() + ROOM_TTL_MS);
	}

	async alarm() {
		this.closeAll("ended");
		await this.ctx.storage.deleteAll();
	}

	private tag(ws: WebSocket): Tag {
		return ws.deserializeAttachment() as Tag;
	}

	private sockets(role?: "host" | "guest"): WebSocket[] {
		return this.ctx.getWebSockets(role);
	}

	private send(ws: WebSocket, msg: unknown) {
		try {
			ws.send(JSON.stringify(msg));
		} catch {
			// socket already gone
		}
	}

	private toHost(msg: unknown) {
		for (const h of this.sockets("host")) this.send(h, msg);
	}

	private approvedSet = new Set<string>();
	private loaded = false;

	private async approved(): Promise<Set<string>> {
		if (!this.loaded) {
			this.approvedSet = new Set((await this.ctx.storage.get<string[]>("approved")) ?? []);
			this.loaded = true;
		}
		return this.approvedSet;
	}

	private approvedGuests(): WebSocket[] {
		return this.sockets("guest").filter((ws) => this.approvedSet.has(this.tag(ws).id));
	}

	private guestList() {
		return this.approvedGuests().map((ws) => ({ id: this.tag(ws).id, name: this.tag(ws).name }));
	}

	private closeAll(reason: string) {
		for (const ws of this.sockets()) {
			this.send(ws, { t: reason });
			try {
				ws.close(1000, reason);
			} catch {
				// already closed
			}
		}
	}

	async fetch(request: Request): Promise<Response> {
		if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected a WebSocket", { status: 426 });
		const url = new URL(request.url);
		const key = await this.ctx.storage.get<string>("key");
		if (!key) return new Response("No such Jam", { status: 404 });

		const role = url.searchParams.get("role") === "host" ? "host" : "guest";
		const name = clean(url.searchParams.get("name")) || (role === "host" ? "Host" : "Guest");
		const id = clean(url.searchParams.get("id"), 64) || crypto.randomUUID();
		if (role === "host" && url.searchParams.get("key") !== key) return new Response("Wrong key", { status: 403 });
		const approved = await this.approved();
		if (role === "guest" && !approved.has(id) && this.sockets("guest").length >= MAX_GUESTS * 2) {
			return new Response("Jam is full", { status: 429 });
		}

		const pair = new WebSocketPair();
		const [client, server] = Object.values(pair);
		// One socket per host / guest id: a reconnect replaces the old one.
		for (const old of this.ctx.getWebSockets(role)) {
			if (role === "host" || this.tag(old).id === id) {
				try {
					old.close(1000, "replaced");
				} catch {
					// already closed
				}
			}
		}
		this.ctx.acceptWebSocket(server, [role]);
		server.serializeAttachment({ role, id, name } satisfies Tag);
		await this.touch();

		if (role === "host") {
			this.send(server, { t: "hello", now: Date.now() });
			this.send(server, { t: "guests", list: this.guestList() });
			// Anyone still waiting to be let in.
			for (const g of this.sockets("guest")) {
				const tg = this.tag(g);
				if (!approved.has(tg.id)) this.send(server, { t: "request", id: tg.id, name: tg.name });
			}
			for (const g of this.approvedGuests()) this.send(g, { t: "hostBack" });
		} else if (approved.has(id)) {
			this.send(server, { t: "welcome", now: Date.now() });
			const state = await this.ctx.storage.get("state");
			if (state) this.send(server, state);
			this.toHost({ t: "guests", list: this.guestList() });
		} else {
			this.send(server, { t: "waiting" });
			if (this.sockets("host").length === 0) this.send(server, { t: "hostAway" });
			this.toHost({ t: "request", id, name });
		}
		return new Response(null, { status: 101, webSocket: client });
	}

	async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
		if (typeof raw !== "string" || raw.length > 64_000) return;
		let m: Record<string, unknown>;
		try {
			m = JSON.parse(raw);
		} catch {
			return;
		}
		const me = this.tag(ws);
		if (m.t === "ping") return this.send(ws, { t: "pong", c: m.c, s: Date.now() });
		const approved = await this.approved();

		if (me.role === "host") {
			switch (m.t) {
				case "state": {
					const state = { ...m, s: Date.now() };
					await this.ctx.storage.put("state", state);
					for (const g of this.approvedGuests()) this.send(g, state);
					break;
				}
				case "approve": {
					const id = String(m.id ?? "");
					const ok = m.ok === true;
					if (ok) {
						approved.add(id);
						await this.ctx.storage.put("approved", [...approved]);
					}
					for (const g of this.sockets("guest")) {
						if (this.tag(g).id !== id) continue;
						if (ok) {
							this.send(g, { t: "welcome", now: Date.now() });
							const state = await this.ctx.storage.get("state");
							if (state) this.send(g, state);
						} else {
							this.send(g, { t: "denied" });
							g.close(1000, "denied");
						}
					}
					this.toHost({ t: "guests", list: this.guestList() });
					break;
				}
				case "kick": {
					const id = String(m.id ?? "");
					approved.delete(id);
					await this.ctx.storage.put("approved", [...approved]);
					for (const g of this.sockets("guest")) {
						if (this.tag(g).id === id) {
							this.send(g, { t: "kicked" });
							g.close(1000, "kicked");
						}
					}
					this.toHost({ t: "guests", list: this.guestList() });
					break;
				}
				case "to": {
					const id = String(m.id ?? "");
					for (const g of this.approvedGuests()) if (this.tag(g).id === id) this.send(g, m.msg);
					break;
				}
				case "end":
					this.closeAll("ended");
					await this.ctx.storage.deleteAll();
					this.approvedSet.clear();
					break;
			}
		} else if (approved.has(me.id) && m.t === "req") {
			this.toHost({ ...m, from: me.id, name: me.name });
		}
		await this.touch();
	}

	async webSocketClose(ws: WebSocket) {
		const me = this.tag(ws);
		if (me.role === "host") {
			for (const g of this.approvedGuests()) this.send(g, { t: "hostAway" });
		} else {
			await this.approved();
			this.toHost({ t: "guests", list: this.guestList().filter((g) => g.id !== me.id) });
		}
	}

	async webSocketError(ws: WebSocket) {
		await this.webSocketClose(ws);
	}
}

export default {
	async fetch(request, _env, ctx): Promise<Response> {
		const url = new URL(request.url);
		const parts = url.pathname.split("/").filter(Boolean);
		if (request.method === "OPTIONS") {
			return new Response(null, {
				headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, POST", "access-control-allow-headers": "content-type" },
			});
		}
		if (parts.length === 0) return json({ service: "spotvault-jam", ok: true });
		if (parts[0] !== "rooms") return json({ error: "not found" }, 404);

		const room = (code: string) => ctx.exports.JamRoom.get(ctx.exports.JamRoom.idFromName(code));

		if (parts.length === 1 && request.method === "POST") {
			const key = randomCode(24);
			for (let i = 0; i < 5; i++) {
				const code = randomCode(6);
				if (await room(code).create(key)) return json({ code, key });
			}
			return json({ error: "try again" }, 503);
		}

		const code = (parts[1] ?? "").toUpperCase();
		if (!/^[A-Z0-9]{6}$/.test(code)) return json({ error: "bad code" }, 400);
		if (parts.length === 2 && request.method === "GET") return json(await room(code).info());
		if (parts.length === 3 && parts[2] === "ws") return room(code).fetch(request);
		return json({ error: "not found" }, 404);
	},
} satisfies ExportedHandler<Env>;
