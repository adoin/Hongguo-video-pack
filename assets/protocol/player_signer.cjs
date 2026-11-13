// SPDX-License-Identifier: GPL-3.0-only
// Adapted from hongguoTV-livingroom PlayerSigner.kt, 52901f74586a.
// Upstream lineage: N3urda/hongguoTV 7444bb01 and ch6vip/fqapp Rust signers.
"use strict";
const crypto = require("node:crypto");
const MASK = (1n << 64n) - 1n;
const rotl = (v, n) => ((v << BigInt(n)) | (v >> BigInt(64 - n))) & MASK;
const rotr = (v, n) => rotl(v, 64 - n);
const hash = (name, b) => crypto.createHash(name).update(b).digest();
const le64 = (v) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(v & MASK);
  return b;
};
const pkcs = (b) =>
  Buffer.concat([b, Buffer.alloc(16 - (b.length % 16), 16 - (b.length % 16))]);
function varint(v) {
  v = Number(BigInt(v) & 0xffffffffn);
  const out = [];
  while (v >= 128) {
    out.push((v & 127) | 128);
    v = Math.floor(v / 128);
  }
  out.push(v);
  return Buffer.from(out);
}
function pb(fields) {
  return Buffer.concat(
    fields.map(([n, v]) =>
      typeof v === "number" || typeof v === "bigint"
        ? Buffer.concat([varint(n * 8), varint(v)])
        : Buffer.concat([
            varint(n * 8 + 2),
            varint(Buffer.byteLength(v)),
            Buffer.isBuffer(v) ? v : Buffer.from(v),
          ]),
    ),
  );
}
function argus(query, ts, device, random, stubHex = "") {
  const k = Buffer.from(
    "fc78e0a9657a0c748ce51559903ccf03510e51d3cff232d71343e88a321c5304",
    "hex",
  );
  const keys = Array.from({ length: 4 }, (_, i) => k.readBigUInt64LE(i * 8));
  const z = 0x3dc94c3a046d678bn;
  for (let i = 4; i < 72; i++) {
    let t = rotr(keys[i - 1], 3) ^ keys[i - 3];
    t ^= rotr(t, 1);
    const bit = (z >> BigInt((i - 4) % 62)) & 1n;
    keys[i] = (~keys[i - 4] ^ t ^ bit ^ 3n) & MASK;
  }
  const params = new URLSearchParams(query);
  const bean = pkcs(
    pb([
      [1, 1077940818],
      [2, 2],
      [3, random],
      [4, params.get("aid") || "1967"],
      [5, device.device_id],
      [6, "1611921764"],
      [7, params.get("version_name") ?? ""],
      [8, "v04.04.05-ov-android"],
      [9, 134744640],
      [10, Buffer.alloc(8)],
      [11, 0],
      [12, BigInt(ts) * 2n],
      [
        13,
        hash(
          "sm3",
          stubHex ? Buffer.from(stubHex, "hex") : Buffer.alloc(16),
        ).subarray(0, 6),
      ],
      [14, hash("sm3", Buffer.from(query)).subarray(0, 6)],
      [
        15,
        pb([
          [1, 1],
          [2, 1],
          [3, 1],
          [7, 0xc792eccc],
        ]),
      ],
      [16, ""],
      [20, "none"],
      [21, 738],
      [
        23,
        pb([
          [1, "NX551J"],
          [2, 8196],
          [4, 0x80e0d800],
        ]),
      ],
      [25, 2],
    ]),
  );
  const chunks = [];
  for (let at = 0; at < bean.length; at += 16) {
    let x = bean.readBigUInt64LE(at),
      y = bean.readBigUInt64LE(at + 8);
    for (const key of keys) {
      const next = (x ^ (rotl(y, 1) & rotl(y, 8)) ^ rotl(y, 2) ^ key) & MASK;
      x = y;
      y = next;
    }
    chunks.push(le64(x), le64(y));
  }
  const magic = Buffer.from("f2f7fcfff2f7fcff", "hex");
  const raw = Buffer.concat([
    magic,
    ...chunks,
    Buffer.from("eafb2cfe8568519154", "hex"),
  ]);
  for (let i = 8; i < raw.length; i++) raw[i] ^= magic[i % 8];
  raw.reverse();
  const cipher = crypto.createCipheriv(
    "aes-128-cbc",
    Buffer.from("d31e3718288a1027baab59f146a09a9c", "hex"),
    Buffer.from("ea180a0336ed352fcd24e4d50018ae54", "hex"),
  );
  cipher.setAutoPadding(false);
  return Buffer.concat([
    Buffer.from([0xf2, 0x81]),
    cipher.update(pkcs(Buffer.concat([raw, Buffer.from("ao")]))),
    cipher.final(),
  ]).toString("base64");
}
function ladon(ts, random, aid = "8662") {
  const bytes = Buffer.from(
    hash("md5", Buffer.concat([random, Buffer.from(aid)])).toString("hex"),
  );
  const words = Array.from({ length: 4 }, (_, i) =>
    bytes.readBigUInt64LE(i * 8),
  );
  let a = words[0],
    b = words[1];
  const queue = [words[2], words[3]],
    table = [a];
  for (let i = 0; i < 34; i++) {
    let t = ((rotr(b, 8) + a) & MASK) ^ BigInt(i);
    queue.push(t);
    t = (t ^ rotl(a, 3)) & MASK;
    table.push(t);
    a = t;
    b = queue.shift();
  }
  const input = pkcs(Buffer.from(`${ts}-1611921764-${aid}`));
  const chunks = [random];
  for (let i = 0; i < input.length; i += 16) {
    let x = input.readBigUInt64LE(i),
      y = input.readBigUInt64LE(i + 8);
    for (let n = 0; n < 34; n++) {
      y = (table[n] ^ ((x + rotr(y, 8)) & MASK)) & MASK;
      x = (y ^ rotl(x, 3)) & MASK;
    }
    chunks.push(le64(x), le64(y));
  }
  return Buffer.concat(chunks).toString("base64");
}
function sign(
  episode,
  device,
  { now = Date.now(), random = crypto.randomBytes(4), body } = {},
) {
  if (
    !/^\d{1,32}$/.test(episode) ||
    !["device_id", "iid"].every((k) => /^[1-9]\d{15,19}$/.test(device[k]))
  )
    throw Error("Invalid playback identity");
  const ts = Math.floor(now / 1000);
  const post = typeof body === "string";
  const payload = post ? Buffer.from(body, "utf8") : Buffer.alloc(0);
  const stub = post ? hash("md5", payload).toString("hex") : "";
  const values = {
    ...device,
    aid: "8662",
    app_name: "novelread",
    version_code: "73932",
    version_name: "7.3.9.32",
    manifest_version_code: "73932",
    update_version_code: "73932",
    pv_player: "73932",
    ...(post
      ? {}
      : {
          video_id: episode,
          video_id_type: "0",
          device_level: "1",
          need_all_video_definition: "1",
          need_mp4_align: "0",
          use_os_player: "0",
          video_platform: "1024",
          source: "0",
          from_video_id: "",
        }),
    ts: String(ts),
    _rticket: String(now),
  };
  const query = Object.entries(values)
    .map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v))
    .join("&");
  return {
    url:
      "https://api5-normal-sinfonlineb.fqnovel.com" +
      (post
        ? "/novel/player/multi_video_model/v1/?"
        : "/reading/bookapi/video_tab/multi_video_model/v1/?") +
      query,
    method: post ? "POST" : "GET",
    body: payload,
    headers: {
      "User-Agent":
        "com.phoenix.read/73932 (Linux; U; Android 9; zh_CN; DT1901A)",
      Accept: "application/json; charset=utf-8,application/x-protobuf",
      "sdk-version": "2",
      "x-xs-from-web": "0",
      "x-ss-dp": "8662",
      "passport-sdk-version": "50561",
      "x-tt-dt": "",
      "x-tt-store-region": "cn",
      "x-tt-store-region-src": "did",
      "x-tt-request-tag": "t=0;n=0",
      "x-ss-req-ticket": String(ts * 1000),
      "x-khronos": String(ts),
      "x-ladon": ladon(ts, random),
      "x-argus": argus(query, ts, values, random.readUInt32LE(), stub),
      ...(post
        ? {
            "Content-Type": "application/json; charset=UTF-8",
            "x-ss-stub": stub,
          }
        : {}),
    },
  };
}
module.exports = { sign, argus, ladon };
