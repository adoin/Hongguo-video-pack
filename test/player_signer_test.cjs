const test = require("node:test");
const assert = require("node:assert/strict");
const player = require("../assets/protocol/player_signer.cjs");
const crypto = require("node:crypto");

test("original POST binds the actual body and never adds a Medusa header", () => {
  const device = { device_id: "1000000000000001", iid: "2000000000000001" };
  const options = {
    now: 1700000000000,
    random: Buffer.from("01020304", "hex"),
  };
  const body = '{"mixed_video_id_map":{"1004":["123"]}}';
  const signed = player.sign("123", device, { ...options, body });
  assert.equal(signed.method, "POST");
  assert.equal(signed.body.toString(), body);
  assert.equal(
    new URL(signed.url).pathname,
    "/novel/player/multi_video_model/v1/",
  );
  assert.equal(
    signed.headers["x-ss-stub"],
    crypto.createHash("md5").update(body).digest("hex"),
  );
  assert.equal(signed.headers["x-medusa"], undefined);
  const changed = player.sign("123", device, { ...options, body: body + " " });
  assert.notEqual(signed.headers["x-argus"], changed.headers["x-argus"]);
});

test("Argus matches the independently published 551 vector", () => {
  assert.equal(
    player.argus(
      "aid=1967&device_id=X&iid=333",
      1234567890,
      { device_id: "X" },
      554000487,
    ),
    "8oEOCRTb0LQf+M+MsliYu4M9kBzAlzXvFgL/Ub198hyoBGxYfNXLAENmH+K/10JQ+Rbhm2zRxNtNv5wVd885xcb6C6F10zp/9jVeGHGz8plz8W3UXHHNrFKjJptjQElGDbyaVLSKt56+HfwO7ENYMfjVv/5PNi1upVciiHqyOPDDAtwi/fZkwBoU1kC7RolMOuedn4lCg/s0CjnNvxFT0QpF/K0yoW3Zpu30tkadIET7WbZ3+7KT3c1yAA6RKWI4mmw=",
  );
});
test("Ladon matches the independently published fixed-random vector", () => {
  assert.equal(
    player.ladon(1700000000, Buffer.from("01020304", "hex"), "1967"),
    "AQIDBKM7Y7bWnOIUXmTybD6/MpGbuge4sBwUJsyHVivhtMsH",
  );
});
test("playback signs the actual GET query and retains this installation identity", () => {
  const device = { device_id: "1000000000000001", iid: "2000000000000001" };
  const signed = player.sign("123", device, {
    now: 1700000000000,
    random: Buffer.from("01020304", "hex"),
  });
  const url = new URL(signed.url);
  assert.equal(signed.method, "GET");
  assert.equal(signed.body.length, 0);
  assert.equal(
    url.pathname,
    "/reading/bookapi/video_tab/multi_video_model/v1/",
  );
  assert.equal(url.searchParams.get("device_id"), device.device_id);
  assert.equal(url.searchParams.get("video_id"), "123");
  assert.equal(
    Buffer.from(signed.headers["x-argus"], "base64")
      .subarray(0, 2)
      .toString("hex"),
    "f281",
  );
  const other = player.sign("124", device, {
    now: 1700000000000,
    random: Buffer.from("01020304", "hex"),
  });
  assert.notEqual(other.headers["x-argus"], signed.headers["x-argus"]);
  assert.throws(() => player.sign("https://bad.test", device));
});
