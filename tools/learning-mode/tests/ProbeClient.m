#import "ProbeClient.h"
@implementation ProbeClient
- (instancetype)init { if ((self = [super init])) { _committed = @""; _marked = @""; _caretRect = NSMakeRect(500,550,1,18); } return self; }
- (void)insertText:(id)t replacementRange:(NSRange)r { [_editor insertText:t replacementRange:r]; self.committed = [_committed stringByAppendingString:[t isKindOfClass:NSString.class] ? t : [t string]]; self.marked = @""; }
- (void)setMarkedText:(id)t selectionRange:(NSRange)s replacementRange:(NSRange)r { [_editor setMarkedText:t selectedRange:s replacementRange:r]; self.marked = [t isKindOfClass:NSString.class] ? t : [t string]; }
- (NSRange)selectedRange { return NSMakeRange(_committed.length, 0); }
- (NSRange)markedRange { return NSMakeRange(_committed.length, _marked.length); }
- (NSAttributedString*)attributedSubstringFromRange:(NSRange)r { return nil; }
- (NSInteger)length { return _committed.length; }
- (NSInteger)characterIndexForPoint:(NSPoint)p tracking:(IMKLocationToOffsetMappingMode)m inMarkedRange:(BOOL*)r { return 0; }
- (NSDictionary*)attributesForCharacterIndex:(NSUInteger)i lineHeightRectangle:(NSRect*)r { if(r) {
  if (_editor.hasMarkedText) *r=[_editor firstRectForCharacterRange:NSMakeRange(_editor.markedRange.location,1) actualRange:NULL];
  else *r=_caretRect;
} return @{}; }
- (NSArray*)validAttributesForMarkedText { return @[]; }
- (void)overrideKeyboardWithKeyboardNamed:(NSString*)n {}
- (void)selectInputMode:(NSString*)i {}
- (BOOL)supportsUnicode { return YES; }
- (NSString*)bundleIdentifier { return @"local.rime.learning.probe"; }
- (CGWindowLevel)windowLevel { return 0; }
@end
