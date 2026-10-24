using System.Security.Cryptography;
using System.Text;
using LocalAIGateway.Core.Installation;

namespace LocalAIGateway.Core.Update;

public interface IEd25519Verifier
{
    Task<bool> VerifyAsync(
        ReadOnlyMemory<byte> publicKey,
        ReadOnlyMemory<byte> message,
        ReadOnlyMemory<byte> signature,
        CancellationToken cancellationToken = default);
}

public sealed class PackageSignaturePolicy(IEd25519Verifier verifier)
{
    private static readonly byte[] Domain = Encoding.ASCII.GetBytes("LocalAIGateway.PackageManifest.v1\0");

    public async Task<(PackageTrustKind TrustKind, string? KeyId)> VerifyAsync(
        PackageManifest manifest,
        ReadOnlyMemory<byte> canonicalManifest,
        PackageSignature signature,
        TrustedUpdateKeys trustedKeys,
        bool allowUnsignedDevelopment,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(manifest);
        ArgumentNullException.ThrowIfNull(signature);
        ArgumentNullException.ThrowIfNull(trustedKeys);
        var actualHash = Convert.ToHexStringLower(SHA256.HashData(canonicalManifest.Span));
        if (!string.Equals(actualHash, signature.ManifestSha256, StringComparison.Ordinal))
        {
            throw new UpdateException("aigw_update_manifest_hash_mismatch", "The package signature does not bind the candidate manifest.");
        }

        if (manifest.Unsigned)
        {
            if (signature.Algorithm != PackageSignature.UnsignedAlgorithm || !allowUnsignedDevelopment)
            {
                throw new UpdateException(
                    allowUnsignedDevelopment ? "aigw_update_signature_required" : "aigw_update_unsigned_not_allowed",
                    allowUnsignedDevelopment
                        ? "Unsigned package metadata is inconsistent."
                        : "Unsigned development updates require explicit authorization.");
            }
            return (PackageTrustKind.UnsignedDevelopment, null);
        }

        if (signature.Algorithm != PackageSignature.Ed25519Algorithm || signature.KeyId is null || signature.Signature is null)
        {
            throw new UpdateException("aigw_update_signature_required", "A signed package must contain an Ed25519 signature.");
        }

        var key = trustedKeys.Keys.SingleOrDefault(candidate =>
            string.Equals(candidate.KeyId, signature.KeyId, StringComparison.Ordinal));
        if (key is null)
        {
            throw new UpdateException("aigw_update_signing_key_untrusted", "The package signing key is not trusted by the installed version.");
        }

        var publicKey = Convert.FromBase64String(key.PublicKey);
        var signatureBytes = Convert.FromBase64String(signature.Signature);
        var message = new byte[Domain.Length + canonicalManifest.Length];
        Domain.CopyTo(message, 0);
        canonicalManifest.CopyTo(message.AsMemory(Domain.Length));
        try
        {
            if (!await verifier.VerifyAsync(publicKey, message, signatureBytes, cancellationToken))
            {
                throw new UpdateException("aigw_update_signature_invalid", "The package Ed25519 signature is invalid.");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(publicKey);
            CryptographicOperations.ZeroMemory(message);
            CryptographicOperations.ZeroMemory(signatureBytes);
        }
        return (PackageTrustKind.Signed, key.KeyId);
    }
}
