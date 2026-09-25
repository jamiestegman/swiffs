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

#endif
