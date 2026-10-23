using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using LocalAIGateway.Core.Credentials;

namespace LocalAIGateway.Windows;

public sealed class WindowsCredentialStore : ICredentialStore, ICredentialTargetCatalog
{
    private const uint GenericCredentialType = 1;
    private const uint LocalMachinePersistence = 2;
    private const int ErrorNotFound = 1168;
    private const int MaxCredentialBlobBytes = 2560;

    public ValueTask SetSecretAsync(
        string target,
        string secret,
        CancellationToken cancellationToken = default)
    {
        EnsureWindows();
        ValidateTarget(target);
        ArgumentNullException.ThrowIfNull(secret);
        cancellationToken.ThrowIfCancellationRequested();

        if (secret.Length == 0)
        {
            throw new CredentialException("aigw_credential_empty", "Credential secret must not be empty.");
        }

        var secretBytes = Encoding.UTF8.GetBytes(secret);
        if (secretBytes.Length > MaxCredentialBlobBytes)
        {
            CryptographicOperations.ZeroMemory(secretBytes);
            throw new CredentialException(
                "aigw_credential_too_large",
                $"Credential secret exceeds {MaxCredentialBlobBytes} UTF-8 bytes.");
        }

        var blob = IntPtr.Zero;
        try
        {
            blob = Marshal.AllocHGlobal(secretBytes.Length);
            Marshal.Copy(secretBytes, 0, blob, secretBytes.Length);

            var credential = new NativeCredential
            {
                Type = GenericCredentialType,
                TargetName = target,
                CredentialBlobSize = checked((uint)secretBytes.Length),
                CredentialBlob = blob,
                Persist = LocalMachinePersistence,
                UserName = Environment.UserName,
            };

            if (!NativeMethods.CredWrite(ref credential, flags: 0))
            {
                throw CreateNativeException(
                    "aigw_credential_write_failed",
                    "Windows Credential Manager rejected the credential write.");
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(secretBytes);
            if (blob != IntPtr.Zero)
            {
                Marshal.Copy(new byte[secretBytes.Length], 0, blob, secretBytes.Length);
                Marshal.FreeHGlobal(blob);
            }
        }

        return ValueTask.CompletedTask;
    }

    public ValueTask<string?> GetSecretAsync(
        string target,
        CancellationToken cancellationToken = default)
    {
        EnsureWindows();
        ValidateTarget(target);
        cancellationToken.ThrowIfCancellationRequested();

        if (!NativeMethods.CredRead(target, GenericCredentialType, flags: 0, out var credentialPointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return ValueTask.FromResult<string?>(null);
            }

            throw CreateNativeException(
                "aigw_credential_read_failed",
                "Windows Credential Manager rejected the credential read.",
                error);
        }

        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(credentialPointer);
            if (credential.CredentialBlobSize == 0)
            {
                return ValueTask.FromResult<string?>(string.Empty);
            }

            var bytes = new byte[credential.CredentialBlobSize];
            try
            {
                Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                return ValueTask.FromResult<string?>(Encoding.UTF8.GetString(bytes));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(bytes);
            }
        }
        finally
        {
            NativeMethods.CredFree(credentialPointer);
        }
    }

    public ValueTask DeleteSecretAsync(
        string target,
        CancellationToken cancellationToken = default)
    {
        EnsureWindows();
        ValidateTarget(target);
        cancellationToken.ThrowIfCancellationRequested();

        if (!NativeMethods.CredDelete(target, GenericCredentialType, flags: 0))
        {
            var error = Marshal.GetLastWin32Error();
            if (error != ErrorNotFound)
            {
                throw CreateNativeException(
                    "aigw_credential_delete_failed",
                    "Windows Credential Manager rejected the credential deletion.",
                    error);
            }
        }

        return ValueTask.CompletedTask;
    }

    public ValueTask<IReadOnlyList<string>> ListTargetsAsync(
        string ownedPrefix,
        CancellationToken cancellationToken = default)
    {
        EnsureWindows();
        ValidateOwnedPrefix(ownedPrefix);
        cancellationToken.ThrowIfCancellationRequested();

        if (!NativeMethods.CredEnumerate(
                ownedPrefix + "*",
                flags: 0,
                out var count,
                out var credentialsPointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return ValueTask.FromResult<IReadOnlyList<string>>([]);
            }

            throw CreateNativeException(
                "aigw_credential_enumeration_failed",
                "Windows Credential Manager rejected the owned credential enumeration.",
                error);
        }

        try
        {
            var entries = new List<(uint Type, string? Target)>();
            for (var index = 0; index < count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var credentialPointer = Marshal.ReadIntPtr(
                    credentialsPointer,
                    checked(index * IntPtr.Size));
                var credential = Marshal.PtrToStructure<NativeCredential>(credentialPointer);
                entries.Add((credential.Type, credential.TargetName));
            }

            return ValueTask.FromResult<IReadOnlyList<string>>(
                FilterOwnedTargets(entries, ownedPrefix));
        }
        finally
        {
            NativeMethods.CredFree(credentialsPointer);
        }
    }

    internal static IReadOnlyList<string> FilterOwnedTargets(
        IEnumerable<(uint Type, string? Target)> entries,
        string ownedPrefix)
    {
        ArgumentNullException.ThrowIfNull(entries);
        ValidateOwnedPrefix(ownedPrefix);
        return entries
            .Where(entry =>
                entry.Type == GenericCredentialType &&
                entry.Target is not null &&
                entry.Target.StartsWith(ownedPrefix, StringComparison.Ordinal))
            .Select(entry => entry.Target!)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(target => target, StringComparer.Ordinal)
            .ToArray();
    }

    private static void ValidateTarget(string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(target);
        if (!target.StartsWith("LocalAIGateway/", StringComparison.Ordinal) ||
            target.Length > 256 ||
            target.Any(char.IsControl))
        {
            throw new CredentialException(
                "aigw_credential_target_invalid",
                "Credential target is outside the Local AI Gateway namespace or is malformed.");
        }
    }

    private static void ValidateOwnedPrefix(string ownedPrefix)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ownedPrefix);
        if (!ownedPrefix.Equals("LocalAIGateway/", StringComparison.Ordinal))
        {
            throw new CredentialException(
                "aigw_credential_prefix_invalid",
                "Credential enumeration is restricted to the Local AI Gateway namespace.");
        }
    }

    private static CredentialException CreateNativeException(
        string errorCode,
        string message,
        int? error = null)
    {
        var win32Error = error ?? Marshal.GetLastWin32Error();
        return new CredentialException(errorCode, message, new Win32Exception(win32Error));
    }

    private static void EnsureWindows()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Windows Credential Manager requires Windows.");
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? TargetName;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? Comment;

        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? TargetAlias;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? UserName;
    }

    private static class NativeMethods
    {
        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredWrite(ref NativeCredential userCredential, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredRead(
            string target,
            uint type,
            uint flags,
            out IntPtr credentialPointer);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CredEnumerate(
            string filter,
            uint flags,
            out int count,
            out IntPtr credentials);

        [DllImport("advapi32.dll", ExactSpelling = true)]
        internal static extern void CredFree(IntPtr buffer);
    }
}
