/* config.h for the vendored LAME 3.100 encoder, written by hand for Apple clang on arm64 and
 * x86_64 in place of what ./configure would produce. Only what libmp3lame reads is set.
 *
 * Like configure on arm64 (its `*)` processor branch, which is what Homebrew's arm64 build gets),
 * neither TAKEHIRO_IEEE754_HACK nor USE_FAST_LOG is defined, and there is no SSE vector code
 * (vector/ and i386/ are not vendored): the encoder is portable C on both architectures.
 * There is no decoder either (no HAVE_MPGLIB, no DECODE_ON_THE_FLY; mpglib_interface.c and
 * mpglib/ are not vendored). */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1

#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1

#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8
#define SIZEOF_UNSIGNED_SHORT 2
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8

/* configure typedefs these itself when the system does not (none does). */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

/* configure always sets this. */
#define LAME_LIBRARY_BUILD 1

#endif
