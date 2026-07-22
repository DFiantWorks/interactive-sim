/* glibc_compat.c
 *
 * Portability shim for the Linux backend libraries. Recent GCC/glibc (>= 2.38)
 * redirect strtol() to the versioned __isoc23_strtol@GLIBC_2.38. A library built
 * on such a host then fails to load under a simulator shipping an OLDER bundled
 * glibc (e.g. oss-cad-suite's vvp, glibc 2.35): "version `GLIBC_2.38' not found".
 *
 * Linking with  -Wl,--wrap=__isoc23_strtol  redirects that reference to the
 * function below, which calls the classic (always-present) strtol -- so the
 * module loads everywhere. Behaviourally identical for the simple base-10 stream
 * parsing the backend does, and a no-op on hosts that don't need it.
 *
 * Linked into every Linux artifact (DPI, VHPI, VPI): the single strtol call lives
 * in the shared backend, so all three inherit the same floor. No stdlib.h include,
 * so the strtol declaration here is itself un-redirected.
 */

#ifdef __cplusplus
extern "C" {
#endif

extern long strtol(const char *, char **, int);

long __wrap___isoc23_strtol(const char *nptr, char **endptr, int base)
{
    return strtol(nptr, endptr, base);
}

#ifdef __cplusplus
}
#endif
