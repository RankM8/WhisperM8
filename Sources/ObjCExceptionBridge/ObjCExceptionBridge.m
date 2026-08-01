#import "ObjCExceptionBridge.h"

BOOL WM8PerformCatchingObjCException(void (NS_NOESCAPE ^block)(void),
                                     NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            // `reason` traegt die eigentliche Diagnose, z. B. „Failed to
            // create tap due to format mismatch, <AVAudioFormat 1 ch,
            // 48000 Hz>" — die gehoert in den Fehler, sonst steht der Nutzer
            // vor einer nichtssagenden Meldung.
            if (exception.reason) {
                info[NSLocalizedDescriptionKey] = exception.reason;
            }
            if (exception.name) {
                info[@"WM8ExceptionName"] = exception.name;
            }
            *error = [NSError errorWithDomain:@"WM8ObjCException"
                                         code:1
                                     userInfo:info];
        }
        return NO;
    }
}
