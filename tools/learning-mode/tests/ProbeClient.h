// Private test text field. Never posts real keyboard events or reads an application.
#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>
@interface ProbeClient : NSObject<IMKTextInput>
@property(nonatomic,copy) NSString *committed;
@property(nonatomic,copy) NSString *marked;
@property(nonatomic,weak) NSTextView *editor;
@property(nonatomic) NSRect caretRect;
@end
