-- Crypto self-test. Run on the table computer (or CraftOS-PC):  test_crypto
-- Verifies SHA-256 / HMAC against published vectors, then the seal/open path.

local crypto = require("lib.crypto")

local pass, fail = 0, 0
local function check(name, got, want)
    if got == want then pass = pass + 1; print("ok   " .. name)
    else fail = fail + 1; print("FAIL " .. name); print("  got  " .. tostring(got)); print("  want " .. tostring(want)) end
end

-- SHA-256 known-answer tests
check("sha256('')", crypto.sha256(""),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("sha256('abc')", crypto.sha256("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("sha256(448-bit msg)", crypto.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

-- HMAC-SHA256 known-answer test (RFC 4231-style)
check("hmac('key', fox)", crypto.hmac("key", "The quick brown fox jumps over the lazy dog"),
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")

-- Seal / open round trip
local key = crypto.deriveKey("device-secret-123", "nonce-abc")
local plain = "hole=A_spades,K_hearts"
local sealed = crypto.seal(key, plain)
check("open(seal(x)) == x", crypto.open(key, sealed), plain)

-- Wrong key fails to open (MAC mismatch -> nil)
local badKey = crypto.deriveKey("device-secret-123", "different-nonce")
check("wrong key -> nil", crypto.open(badKey, sealed), nil)

-- Tampered ciphertext fails
local tampered = { nonce = sealed.nonce, ct = sealed.ct, mac = sealed.mac }
tampered.ct = (sealed.ct:sub(1, 1) == "0" and "1" or "0") .. sealed.ct:sub(2)
check("tampered ct -> nil", crypto.open(key, tampered), nil)

print(string.format("\n%d passed, %d failed", pass, fail))
