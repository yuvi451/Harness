#include "NativeKeychain.h"
#include <Security/Security.h>
// SecItem authenticationUI is ineffective for legacy file keychains (FB16959400).
// These public compatibility APIs remain necessary; scope suppression here only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int32_t HarnessKeychainInteractionGet(bool *allowed) {
    Boolean previous = false;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&previous);
    if (status == errSecSuccess) *allowed = previous;
    return status;
}
int32_t HarnessKeychainInteractionSet(bool allowed) {
    return SecKeychainSetUserInteractionAllowed(allowed);
}
#pragma clang diagnostic pop
