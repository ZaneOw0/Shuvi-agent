using System.Text;
using LocalAIGateway.Core.Installation;
using LocalAIGateway.Core.Update;

namespace LocalAIGateway.Core.Tests;

public sealed class PackageSignatureTests
{
    [Fact]
    public void Signature_metadata_is_canonical_and_rejects_duplicates()
    {
        var value = new PackageSignature(1, "none", null, new string('a', 64), null);
        var bytes = PackageSignatureJson.Serialize(value);
        Assert.Equal(value, PackageSignatureJson.Deserialize(bytes));

        var duplicate = Encoding.UTF8.GetBytes(
            $"{{\"schemaVersion\":1,\"algorithm\":\"none\",\"keyId\":null,\"manifestSha256\":\"{new string('a', 64)}\",\"manifestSha256\":\"{new string('b', 64)}\",\"signature\":null}}");
        var exception = Assert.Throws<UpdateException>(() => PackageSignatureJson.Deserialize(duplicate));
        Assert.Equal("aigw_update_signature_metadata_invalid", exception.ErrorCode);
    }

    [Fact]
    public void Trust_store_rejects_duplicate_ids_and_invalid_key_sizes()
    {
        var duplicate = new TrustedUpdateKeys(1,
        [
            new("release", "Ed25519", Convert.ToBase64String(new byte[32])),
            new("release", "Ed25519", Convert.ToBase64String(new byte[32])),
        ]);
        Assert.Equal(
            "aigw_update_trust_store_invalid",
            Assert.Throws<UpdateException>(() => TrustedUpdateKeysJson.Serialize(duplicate)).ErrorCode);
    }

    [Fact]
    public async Task Unsigned_development_requires_explicit_authorization()
    {
        var manifest = Manifest(unsigned: true);
        var canonical = PackageManifestJson.Serialize(manifest);
        var signature = new PackageSignature(
            1,
            "none",
            null,
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(canonical)),
            null);
        var policy = new PackageSignaturePolicy(new RecordingVerifier(true));

        var denied = await Assert.ThrowsAsync<UpdateException>(() => policy.VerifyAsync(
            manifest, canonical, signature, new TrustedUpdateKeys(1, []), false));
        Assert.Equal("aigw_update_unsigned_not_allowed", denied.ErrorCode);

        var accepted = await policy.VerifyAsync(
            manifest, canonical, signature, new TrustedUpdateKeys(1, []), true);
        Assert.Equal(PackageTrustKind.UnsignedDevelopment, accepted.TrustKind);
    }

    [Fact]
    public async Task Signed_manifest_uses_domain_separated_Ed25519_boundary()
    {
        var manifest = Manifest(unsigned: false);
        var canonical = PackageManifestJson.Serialize(manifest);
        var verifier = new RecordingVerifier(true);
        var signature = new PackageSignature(
            1,
            "Ed25519",
            "release-1",
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(canonical)),
            Convert.ToBase64String(new byte[64]));
        var keys = new TrustedUpdateKeys(1,
            [new TrustedUpdateKey("release-1", "Ed25519", Convert.ToBase64String(new byte[32]))]);

        var result = await new PackageSignaturePolicy(verifier).VerifyAsync(
            manifest, canonical, signature, keys, false);

        Assert.Equal(PackageTrustKind.Signed, result.TrustKind);
        Assert.Equal("release-1", result.KeyId);
        Assert.StartsWith(
            "LocalAIGateway.PackageManifest.v1\0",
            Encoding.ASCII.GetString(verifier.Message));
        Assert.EndsWith(Encoding.UTF8.GetString(canonical), Encoding.UTF8.GetString(verifier.Message));
    }

    [Fact]
    public async Task Signed_manifest_rejects_unknown_key_and_invalid_signature()
    {
        var manifest = Manifest(unsigned: false);
        var canonical = PackageManifestJson.Serialize(manifest);
        var signature = new PackageSignature(
            1, "Ed25519", "unknown",
            Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(canonical)),
            Convert.ToBase64String(new byte[64]));
        var policy = new PackageSignaturePolicy(new RecordingVerifier(false));

        var unknown = await Assert.ThrowsAsync<UpdateException>(() => policy.VerifyAsync(
            manifest, canonical, signature, new TrustedUpdateKeys(1, []), false));
        Assert.Equal("aigw_update_signing_key_untrusted", unknown.ErrorCode);

        var keys = new TrustedUpdateKeys(1,
            [new TrustedUpdateKey("unknown", "Ed25519", Convert.ToBase64String(new byte[32]))]);
        var invalid = await Assert.ThrowsAsync<UpdateException>(() => policy.VerifyAsync(
            manifest, canonical, signature, keys, false));
        Assert.Equal("aigw_update_signature_invalid", invalid.ErrorCode);
    }

    private static PackageManifest Manifest(bool unsigned) => new(
        1,
        "LocalAIGateway",
        "0.2.0-dev",
        "win-x64",
        unsigned,
        [new PackageFile("aigw.exe", 1, new string('0', 64))]);

    private sealed class RecordingVerifier(bool result) : IEd25519Verifier
    {
        public byte[] Message { get; private set; } = [];

        public Task<bool> VerifyAsync(
            ReadOnlyMemory<byte> publicKey,
            ReadOnlyMemory<byte> message,
            ReadOnlyMemory<byte> signature,
            CancellationToken cancellationToken = default)
        {
            Message = message.ToArray();
            return Task.FromResult(result);
        }
    }
}
