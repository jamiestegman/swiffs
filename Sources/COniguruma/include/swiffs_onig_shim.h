#ifndef SWIFFS_ONIG_SHIM_H
#define SWIFFS_ONIG_SHIM_H

#include "oniguruma.h"

/* Swift cannot import address-of macros, expose them as inline functions. */
static inline OnigEncoding swiffs_onig_encoding_utf8(void) { return ONIG_ENCODING_UTF8; }
static inline OnigSyntaxType *swiffs_onig_syntax_default(void) { return ONIG_SYNTAX_DEFAULT; }

/* onig_error_code_to_str is variadic, which Swift cannot call directly. */
static inline int swiffs_onig_error_code_to_str(OnigUChar *buffer, int code, OnigErrorInfo *info) {
  return onig_error_code_to_str(buffer, code, info);
}

/* swiffs patch (src/regexec.c, SWIFFS_PATCHES.md): position-lead regset
   search that reuses per-regex search state across calls on one string. */
extern int swiffs_onig_regset_search_cached(OnigRegSet *set, const OnigUChar *str,
                                            const OnigUChar *end, const OnigUChar *start,
                                            const OnigUChar *range, OnigOptionType option,
                                            int same_string, int *rmatch_pos);

#endif
