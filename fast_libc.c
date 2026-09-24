/* Fast memory and string functions.
 *
 * Darling's libsystem_platform, which provides memcpy/memmove, memset,
 * bzero, memcmp, memchr, strlen, strcmp and strncmp for every Mach-O
 * program, is built without optimization: each loop step stores and
 * reloads its variables through the stack, and memmove copies at most a
 * word at a time. Apple ships hand-written assembly there. Roblox copies
 * memory constantly; in its menu a third of the main thread went to
 * _platform_memmove. These replacements are interposed for all images.
 *
 * Built with -O2 on its own (see build_debug_shim.sh) and without builtins,
 * so the compiler cannot turn these loops back into calls to themselves. */
typedef unsigned long size_t;
typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef char v16 __attribute__((vector_size(16), aligned(1), may_alias));
typedef u64 u64u __attribute__((aligned(1), may_alias));
typedef u32 u32u __attribute__((aligned(1), may_alias));
typedef u16 u16u __attribute__((aligned(1), may_alias));

extern void *memcpy(void *, const void *, size_t);
extern void *memmove(void *, const void *, size_t);
extern void *memset(void *, int, size_t);
extern void bzero(void *, size_t);
extern int memcmp(const void *, const void *, size_t);
extern void *memchr(const void *, int, size_t);
extern size_t strlen(const char *);
extern int strcmp(const char *, const char *);
extern int strncmp(const char *, const char *, size_t);

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

/* Up to 64 bytes; every load happens before any store, so overlap is fine. */
static inline __attribute__((always_inline)) void copy_small(u8 *d, const u8 *s, size_t n) {
    if (n >= 32) {
        v16 a = *(const v16 *)s, b = *(const v16 *)(s + 16);
        v16 c = *(const v16 *)(s + n - 32), e = *(const v16 *)(s + n - 16);
        *(v16 *)d = a; *(v16 *)(d + 16) = b; *(v16 *)(d + n - 32) = c; *(v16 *)(d + n - 16) = e;
    } else if (n >= 16) {
        v16 a = *(const v16 *)s, b = *(const v16 *)(s + n - 16);
        *(v16 *)d = a; *(v16 *)(d + n - 16) = b;
    } else if (n >= 8) {
        u64 a = *(const u64u *)s, b = *(const u64u *)(s + n - 8);
        *(u64u *)d = a; *(u64u *)(d + n - 8) = b;
    } else if (n >= 4) {
        u32 a = *(const u32u *)s, b = *(const u32u *)(s + n - 4);
        *(u32u *)d = a; *(u32u *)(d + n - 4) = b;
    } else if (n >= 2) {
        u16 a = *(const u16u *)s, b = *(const u16u *)(s + n - 2);
        *(u16u *)d = a; *(u16u *)(d + n - 2) = b;
    } else if (n) {
        *d = *s;
    }
}

__attribute__((no_builtin)) static void *fast_memmove(void *dst, const void *src, size_t n) {
    u8 *d = dst;
    const u8 *s = src;
    if (n <= 64) {
        copy_small(d, s, n);
        return dst;
    }
    if ((size_t)(d - s) >= n) {
        /* Forward: no overlap, or the destination is below the source. */
        __asm__ volatile("rep movsb" : "+D"(d), "+S"(s), "+c"(n) : : "memory");
        return dst;
    }
    /* Destination overlaps above the source: copy from the end. */
    while (n >= 16) {
        n -= 16;
        v16 chunk = *(const v16 *)(s + n);
        *(v16 *)(d + n) = chunk;
    }
    copy_small(d, s, n);
    return dst;
}
DYLD_INTERPOSE(fast_memmove, memmove)

__attribute__((no_builtin)) static void *fast_memcpy(void *dst, const void *src, size_t n) {
    return fast_memmove(dst, src, n);  /* Darling's memcpy is memmove too */
}
DYLD_INTERPOSE(fast_memcpy, memcpy)

__attribute__((no_builtin)) static void *fast_memset(void *dst, int value, size_t n) {
    u8 *d = dst;
    u8 byte = (u8)value;
    if (n <= 32) {
        u64 word = 0x0101010101010101UL * byte;
        if (n >= 16) {
            *(u64u *)d = word; *(u64u *)(d + 8) = word;
            *(u64u *)(d + n - 16) = word; *(u64u *)(d + n - 8) = word;
        } else if (n >= 8) {
            *(u64u *)d = word; *(u64u *)(d + n - 8) = word;
        } else if (n >= 4) {
            *(u32u *)d = (u32)word; *(u32u *)(d + n - 4) = (u32)word;
        } else {
            for (size_t i = 0; i < n; i++)
                d[i] = byte;
        }
        return dst;
    }
    __asm__ volatile("rep stosb" : "+D"(d), "+c"(n) : "a"(byte) : "memory");
    return dst;
}
DYLD_INTERPOSE(fast_memset, memset)

__attribute__((no_builtin)) static void fast_bzero(void *dst, size_t n) {
    fast_memset(dst, 0, n);
}
DYLD_INTERPOSE(fast_bzero, bzero)

__attribute__((no_builtin)) static int fast_memcmp(const void *a, const void *b, size_t n) {
    const u8 *x = a, *y = b;
    while (n >= 8 && *(const u64u *)x == *(const u64u *)y) {
        x += 8; y += 8; n -= 8;
    }
    for (; n; n--, x++, y++)
        if (*x != *y)
            return (int)*x - (int)*y;
    return 0;
}
DYLD_INTERPOSE(fast_memcmp, memcmp)

__attribute__((no_builtin)) static void *fast_memchr(const void *p, int value, size_t n) {
    const u8 *s = p;
    u8 c = (u8)value;
    for (; n; n--, s++)
        if (*s == c)
            return (void *)s;
    return 0;
}
DYLD_INTERPOSE(fast_memchr, memchr)

/* Word at a time from an aligned address: an aligned 8-byte load never
 * crosses into the next page, so reading past the terminator is safe. */
__attribute__((no_builtin)) static size_t fast_strlen(const char *text) {
    const char *s = text;
    while ((u64)s & 7) {
        if (!*s)
            return (size_t)(s - text);
        s++;
    }
    const u64 *w = (const u64 *)s;
    for (;;) {
        u64 v = *w;
        if ((v - 0x0101010101010101UL) & ~v & 0x8080808080808080UL)
            break;
        w++;
    }
    s = (const char *)w;
    while (*s)
        s++;
    return (size_t)(s - text);
}
DYLD_INTERPOSE(fast_strlen, strlen)

__attribute__((no_builtin)) static int fast_strcmp(const char *a, const char *b) {
    const u8 *x = (const u8 *)a, *y = (const u8 *)b;
    while (*x && *x == *y) {
        x++; y++;
    }
    return (int)*x - (int)*y;
}
DYLD_INTERPOSE(fast_strcmp, strcmp)

__attribute__((no_builtin)) static int fast_strncmp(const char *a, const char *b, size_t n) {
    const u8 *x = (const u8 *)a, *y = (const u8 *)b;
    for (; n; n--, x++, y++) {
        if (*x != *y)
            return (int)*x - (int)*y;
        if (!*x)
            return 0;
    }
    return 0;
}
DYLD_INTERPOSE(fast_strncmp, strncmp)
