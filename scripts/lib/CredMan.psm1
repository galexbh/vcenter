# Lectura de credenciales genéricas desde Windows Credential Manager (advapi32 CredReadW).
# Sin dependencias externas. Las credenciales se guardan con scripts/Set-GovcCredential.ps1.

Set-StrictMode -Version Latest

if (-not ('GovcCredMan' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class GovcCredMan
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    private const int CRED_TYPE_GENERIC = 1;

    // Devuelve { usuario, contraseña } o null si no existe.
    public static string[] Read(string target)
    {
        IntPtr ptr;
        if (!CredRead(target, CRED_TYPE_GENERIC, 0, out ptr)) return null;
        try
        {
            var c = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
            string secret = c.CredentialBlobSize > 0
                ? Marshal.PtrToStringUni(c.CredentialBlob, c.CredentialBlobSize / 2)
                : string.Empty;
            return new[] { c.UserName, secret };
        }
        finally
        {
            CredFree(ptr);
        }
    }
}
'@
}

function Get-GovcCredential {
    <# Devuelve un PSCredential para el target dado, o lanza si no existe. #>
    param([Parameter(Mandatory)][string]$Target)
    $pair = [GovcCredMan]::Read($Target)
    if (-not $pair) {
        throw "No hay credencial '$Target' en Credential Manager. Ejecuta: ./scripts/Set-GovcCredential.ps1 -Env <entorno>"
    }
    $secure = ConvertTo-SecureString -String $pair[1] -AsPlainText -Force
    $pair[1] = $null
    return [pscredential]::new($pair[0], $secure)
}

function Test-GovcCredential {
    param([Parameter(Mandatory)][string]$Target)
    return [bool]([GovcCredMan]::Read($Target))
}

Export-ModuleMember -Function Get-GovcCredential, Test-GovcCredential
