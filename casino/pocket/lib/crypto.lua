-- crypto.lua — self-contained SHA-256, HMAC-SHA256, and an authenticated
-- stream cipher (SHA-256 in counter mode + HMAC). Pure Lua, no dependence on
-- bit32/bit, so it runs identically under CC:Tweaked and standalone Lua 5.1–5.4.
--
-- This exists so hole cards travel the rednet airwaves as ciphertext: a sniffer
-- that opens a pocket's channel sees {nonce, ct, mac}, never the cards.
--
-- It is not industrial-grade crypto, but it defeats every adversary available
-- inside Minecraft (a computer running rednet/modem.receive). The deck never
-- leaves the server, so the only thing worth stealing in transit is two cards,
-- and those are sealed under a per-session key derived from a never-transmitted
-- device key.

local M = {}

-- ─── 32-bit bitwise ops via pure arithmetic ──────────────────────────────────
-- Loop over the 32 bit positions. Slow per call, but we only hash a few tiny
-- inputs per hand, so total cost is well under a frame.

local function bitop(a, b, fn)
    local r, p = 0, 1
    for _ = 1, 32 do
        local abit, bbit = a % 2, b % 2
        r = r + fn(abit, bbit) * p
        a = (a - abit) / 2
        b = (b - bbit) / 2
        p = p * 2
    end
    return r
end

local function band(a, b) return bitop(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
local function bor(a, b)  return bitop(a, b, function(x, y) return (x == 1 or y == 1) and 1 or 0 end) end
local function bxor(a, b) return bitop(a, b, function(x, y) return (x ~= y) and 1 or 0 end) end
local function bnot(a)    return 4294967295 - a end

local function rshift(a, n) return math.floor(a / 2 ^ n) % 4294967296 end
-- Keep only the low (32-n) bits BEFORE multiplying, so the product never exceeds
-- 2^32 and stays inside the exact-integer range of a double (avoids a silent
-- precision bug for large shifts).
local function lshift(a, n) return (a % 2 ^ (32 - n)) * 2 ^ n end
local function rrotate(a, n) return bor(rshift(a, n), lshift(a, 32 - n)) end

-- ─── SHA-256 ─────────────────────────────────────────────────────────────────

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function toBytes(n)  -- 32-bit int -> 4 big-endian bytes
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

-- Returns the raw 32-byte digest of `msg` (binary string).
function M.digest(msg)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    -- pad
    local len = #msg
    local bitlen = len * 8
    msg = msg .. "\128"
    while #msg % 64 ~= 56 do msg = msg .. "\0" end
    -- 64-bit length, big-endian (high word almost always 0 for our inputs)
    msg = msg .. toBytes(math.floor(bitlen / 4294967296)) .. toBytes(bitlen % 4294967296)

    for chunk = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = ((a * 256 + b) * 256 + c) * 256 + d
        end
        for i = 16, 63 do
            local s0 = bxor(bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18)), rshift(w[i - 15], 3))
            local s1 = bxor(bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19)), rshift(w[i - 2], 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (h + S1 + ch + K[i + 1] + w[i]) % 4294967296
            local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = (S0 + maj) % 4294967296
            h, g, f, e = g, f, e, (d + t1) % 4294967296
            d, c, b, a = c, b, a, (t1 + t2) % 4294967296
        end

        h0, h1, h2, h3 = (h0 + a) % 4294967296, (h1 + b) % 4294967296, (h2 + c) % 4294967296, (h3 + d) % 4294967296
        h4, h5, h6, h7 = (h4 + e) % 4294967296, (h5 + f) % 4294967296, (h6 + g) % 4294967296, (h7 + h) % 4294967296
    end

    return toBytes(h0) .. toBytes(h1) .. toBytes(h2) .. toBytes(h3)
        .. toBytes(h4) .. toBytes(h5) .. toBytes(h6) .. toBytes(h7)
end

local function toHex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Hex digest (handy for ids / fingerprints / tests).
function M.sha256(msg) return toHex(M.digest(msg)) end

-- ─── HMAC-SHA256 ─────────────────────────────────────────────────────────────

local BLOCK = 64

function M.hmacRaw(key, msg)
    if #key > BLOCK then key = M.digest(key) end
    key = key .. string.rep("\0", BLOCK - #key)
    local opad, ipad = {}, {}
    for i = 1, BLOCK do
        local k = key:byte(i)
        opad[i] = string.char(bxor(k, 0x5c))
        ipad[i] = string.char(bxor(k, 0x36))
    end
    opad = table.concat(opad)
    ipad = table.concat(ipad)
    return M.digest(opad .. M.digest(ipad .. msg))
end

function M.hmac(key, msg) return toHex(M.hmacRaw(key, msg)) end

-- ─── Stream cipher: SHA-256 counter-mode keystream, XOR'd into the plaintext ──

local function keystream(key, nonce, n)
    local out, counter = {}, 0
    while #table.concat(out) < n do
        out[#out + 1] = M.hmacRaw(key, nonce .. ":" .. counter)
        counter = counter + 1
    end
    return table.concat(out):sub(1, n)
end

local function xorStr(a, b)  -- a, b equal length
    local out = {}
    for i = 1, #a do out[i] = string.char(bxor(a:byte(i), b:byte(i))) end
    return table.concat(out)
end

-- 16-byte random nonce. Uses math.random; seed it once at startup.
local function randNonce()
    local t = {}
    for i = 1, 16 do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

-- Seal a plaintext string under `key`. Returns {nonce, ct, mac} (hex strings),
-- safe to drop straight into a rednet message.
function M.seal(key, plaintext)
    local nonce = randNonce()
    local ct = xorStr(plaintext, keystream(key, nonce, #plaintext))
    local mac = M.hmacRaw(key, nonce .. ct)
    return { nonce = toHex(nonce), ct = toHex(ct), mac = toHex(mac) }
end

local function fromHex(s)
    return (s:gsub("..", function(h) return string.char(tonumber(h, 16)) end))
end

-- Open a sealed table. Returns the plaintext string, or nil if the MAC fails
-- (tampered, replayed under a different key, or just garbage).
function M.open(key, sealed)
    if type(sealed) ~= "table" or not (sealed.nonce and sealed.ct and sealed.mac) then return nil end
    local nonce, ct = fromHex(sealed.nonce), fromHex(sealed.ct)
    local expect = M.hmacRaw(key, nonce .. ct)
    if expect ~= fromHex(sealed.mac) then return nil end
    return xorStr(ct, keystream(key, nonce, #ct))
end

-- Derive a per-session key from a long-lived device key + a fresh nonce.
function M.deriveKey(deviceKey, nonce) return M.hmacRaw(deviceKey, "session:" .. nonce) end

return M
