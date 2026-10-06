#ifndef KEYCHAIN_SHIM_H
#define KEYCHAIN_SHIM_H

#include <Security/Security.h>

CF_ASSUME_NONNULL_BEGIN

/// Returns a SecAccess whose decrypt ACL allows any application to read the item
/// without a prompt. Ad-hoc signed builds get a new code identity on every rebuild,
/// so a per-app ACL would trigger a keychain prompt after each build.
SecAccessRef _Nullable NBCreateOpenAccess(CFStringRef label) CF_RETURNS_RETAINED;

CF_ASSUME_NONNULL_END

#endif
