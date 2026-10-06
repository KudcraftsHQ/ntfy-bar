#include "KeychainShim.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

SecAccessRef NBCreateOpenAccess(CFStringRef label) {
    SecAccessRef access = NULL;
    if (SecAccessCreate(label, NULL, &access) != errSecSuccess || access == NULL) {
        return NULL;
    }
    CFArrayRef acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt);
    if (acls != NULL) {
        for (CFIndex i = 0; i < CFArrayGetCount(acls); i++) {
            SecACLRef acl = (SecACLRef)CFArrayGetValueAtIndex(acls, i);
            CFArrayRef apps = NULL;
            CFStringRef desc = NULL;
            SecKeychainPromptSelector selector = 0;
            if (SecACLCopyContents(acl, &apps, &desc, &selector) == errSecSuccess) {
                // NULL application list == any application may access.
                SecACLSetContents(acl, NULL, desc != NULL ? desc : label, selector);
                if (apps != NULL) CFRelease(apps);
                if (desc != NULL) CFRelease(desc);
            }
        }
        CFRelease(acls);
    }
    return access;
}

#pragma clang diagnostic pop
