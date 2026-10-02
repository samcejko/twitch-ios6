#import "TWChatView.h"
#import "TWEmotePickerView.h"
#import "TWImageLoader.h"
#import "TWEmotes.h"
#import "TWSettings.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"
#import <QuartzCore/QuartzCore.h>

static const NSUInteger TWChatMaxMessages = 400;
static const NSUInteger TWChatTrimTo = 300;
static const CGFloat TWChatCellPadV = 4;
static const CGFloat TWChatCellPadH = 8;
static const CGFloat TWChatInputHeight = 44;

#pragma mark - Line view

// Draws the text of one line; the images are UIImageViews above it
@interface TWChatLineView : UIView
@property (nonatomic, strong) TWChatLayout *layout;
@end

@implementation TWChatLineView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setLayout:(TWChatLayout *)layout
{
    _layout = layout;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    [self.layout drawInContext:UIGraphicsGetCurrentContext()];
}

@end

#pragma mark - Cell

@interface TWChatCell ()
@property (nonatomic, strong) TWChatMessage *message;
@property (nonatomic, strong) TWChatLayout *layout;
@property (nonatomic, strong) TWChatLineView *lineView;
@property (nonatomic, strong) NSMutableArray *imageViews;
@property (nonatomic, strong) UIView *separator;
@end

@implementation TWChatCell

+ (NSString *)reuseIdentifier { return @"chat"; }

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _lineView = [[TWChatLineView alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_lineView];
        _imageViews = [NSMutableArray array];
        _separator = [[UIView alloc] initWithFrame:CGRectZero];
        _separator.hidden = YES;
        [self.contentView addSubview:_separator];
    }
    return self;
}

- (void)configureWithMessage:(TWChatMessage *)message layout:(TWChatLayout *)layout style:(TWChatStyle *)style alternate:(BOOL)alternate
{
    TWTheme *t = [TWTheme shared];
    self.message = message;
    self.layout = layout;
    self.lineView.layout = layout;
    UIColor *background = [t chatBackgroundColor];
    if (message.isMention) background = [t chatMentionColor];
    else if (message.isHighlighted || message.isFirstMessage) background = [t chatHighlightColor];
    else if (alternate) background = t.isDark ? [UIColor colorWithWhite:0.13 alpha:1] : [UIColor colorWithWhite:0.965 alpha:1];
    self.backgroundColor = background;
    self.contentView.backgroundColor = background;
    self.lineView.alpha = message.isDeleted ? 0.6 : 1.0;
    self.separator.hidden = ![TWSettings chatSeparators];
    self.separator.backgroundColor = [t chatSeparatorColor];
    [self refreshImages];
    [self setNeedsLayout];
}

- (void)refreshImages
{
    NSArray *slots = self.layout.imageSlots;
    while (self.imageViews.count < slots.count) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:iv];
        [self.imageViews addObject:iv];
    }
    TWImageLoader *loader = [TWImageLoader shared];
    for (NSUInteger i = 0; i < self.imageViews.count; i++) {
        UIImageView *iv = self.imageViews[i];
        if (i >= slots.count) { iv.hidden = YES; iv.image = nil; continue; }
        TWChatImageSlot *slot = slots[i];
        iv.hidden = NO;
        iv.frame = CGRectOffset(slot.frame, TWChatCellPadH, TWChatCellPadV);
        UIImage *image = [loader imageForURL:slot.url];   // (starts the download when needed)
        if (image != iv.image) iv.image = image;
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    self.lineView.frame = CGRectMake(TWChatCellPadH, TWChatCellPadV, b.size.width - 2 * TWChatCellPadH, MAX(0, b.size.height - TWChatCellPadV));
    self.separator.frame = CGRectMake(0, b.size.height - 1, b.size.width, 1);
    [self refreshImages];
}

@end

#pragma mark - Chat view

@interface TWChatView () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIActionSheetDelegate, TWEmotePickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *messages;
@property (nonatomic, strong) TWChatStyle *style;
@property (nonatomic, strong) UIButton *moreMessagesButton;
@property (nonatomic) BOOL stuckToBottom;
@property (nonatomic) NSUInteger unseen;
// input
@property (nonatomic, strong) UIImageView *inputBackground;
@property (nonatomic, strong) UIImageView *fieldBackground;
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIButton *emoteButton;
@property (nonatomic, strong) TWEmotePickerView *picker;
@property (nonatomic) BOOL pickerShown;
@property (nonatomic) CGFloat keyboardOverlap;
@property (nonatomic) BOOL keyboardVisible;
@property (nonatomic) BOOL sending;
@property (nonatomic, strong) TWChatMessage *tappedMessage;
@property (nonatomic, copy) NSString *tappedLink;
@end

@implementation TWChatView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _messages = [NSMutableArray array];
        _stuckToBottom = YES;
        self.clipsToBounds = YES;

        _tableView = [[UITableView alloc] initWithFrame:self.bounds style:UITableViewStylePlain];
        _tableView.dataSource = self;
        _tableView.delegate = self;
        _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        _tableView.allowsSelection = NO;
        _tableView.scrollsToTop = NO;
        [_tableView registerClass:[TWChatCell class] forCellReuseIdentifier:[TWChatCell reuseIdentifier]];
        [self addSubview:_tableView];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tableTapped:)];
        tap.cancelsTouchesInView = NO;
        [_tableView addGestureRecognizer:tap];
        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(tablePressed:)];
        press.minimumPressDuration = 0.5;
        [_tableView addGestureRecognizer:press];

        _moreMessagesButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _moreMessagesButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [_moreMessagesButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_moreMessagesButton addTarget:self action:@selector(moreMessagesTapped) forControlEvents:UIControlEventTouchUpInside];
        _moreMessagesButton.hidden = YES;
        [self addSubview:_moreMessagesButton];

        _inputBackground = [[UIImageView alloc] initWithFrame:CGRectZero];
        _inputBackground.hidden = YES;
        [self addSubview:_inputBackground];
        _fieldBackground = [[UIImageView alloc] initWithFrame:CGRectZero];
        _fieldBackground.hidden = YES;
        [self addSubview:_fieldBackground];
        _field = [[UITextField alloc] initWithFrame:CGRectZero];
        _field.delegate = self;
        _field.font = [UIFont systemFontOfSize:15];
        _field.returnKeyType = UIReturnKeySend;
        _field.enablesReturnKeyAutomatically = YES;
        _field.autocorrectionType = UITextAutocorrectionTypeDefault;
        _field.placeholder = L(@"Send a message");
        _field.hidden = YES;
        [self addSubview:_field];
        _emoteButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_emoteButton addTarget:self action:@selector(emoteTapped) forControlEvents:UIControlEventTouchUpInside];
        _emoteButton.showsTouchWhenHighlighted = YES;
        _emoteButton.hidden = YES;
        [self addSubview:_emoteButton];
        _sendButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        _sendButton.titleLabel.shadowOffset = CGSizeMake(0, -1);
        [_sendButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_sendButton setTitleShadowColor:[UIColor colorWithWhite:0 alpha:0.35] forState:UIControlStateNormal];
        [_sendButton setTitle:L(@"Send") forState:UIControlStateNormal];
        [_sendButton addTarget:self action:@selector(sendTapped) forControlEvents:UIControlEventTouchUpInside];
        _sendButton.hidden = YES;
        [self addSubview:_sendButton];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(imageLoaded:) name:TWImageDidLoadNotification object:nil];
        [nc addObserver:self selector:@selector(emotesChanged) name:TWEmotesDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(settingsChanged) name:TWSettingsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
        [nc addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
        [self applyTheme];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Theme and layout

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    self.backgroundColor = [t chatBackgroundColor];
    self.tableView.backgroundColor = [t chatBackgroundColor];
    self.tableView.indicatorStyle = t.isDark ? UIScrollViewIndicatorStyleWhite : UIScrollViewIndicatorStyleDefault;
    self.inputBackground.image = [t barBackgroundImage];
    self.fieldBackground.image = [t textFieldBackgroundImage];
    self.field.textColor = [t inputTextColor];
    self.field.keyboardAppearance = t.isDark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    [self.emoteButton setImage:[t emoteIcon] forState:UIControlStateNormal];
    [self.sendButton setBackgroundImage:[t accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [self.sendButton setBackgroundImage:[t accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [self.sendButton setBackgroundImage:[t accentButtonImageHighlighted:NO disabled:YES] forState:UIControlStateDisabled];
    [self.moreMessagesButton setBackgroundImage:[t pillImageWithColor:[t accentColor]] forState:UIControlStateNormal];
    [self.picker applyTheme];
    [self invalidateLayouts];
}

- (void)settingsChanged
{
    [self invalidateLayouts];
}

- (void)emotesChanged
{
    // badges and third-party emotes arrived: lines that showed none are laid out again
    [self invalidateLayouts];
}

- (void)invalidateLayouts
{
    self.style = nil;
    for (TWChatMessage *m in self.messages) m.layout = nil;
    [self.tableView reloadData];
    if (self.stuckToBottom) [self scrollToBottom];
}

- (CGFloat)textWidth
{
    return self.tableView.bounds.size.width - 2 * TWChatCellPadH;
}

- (TWChatStyle *)currentStyle
{
    CGFloat width = [self textWidth];
    if (!self.style || fabs(self.style.width - width) > 0.5) self.style = [TWChatStyle currentStyleForWidth:width channelId:self.channelId];
    return self.style;
}

- (void)setChannelId:(NSString *)channelId
{
    _channelId = [channelId copy];
    self.style = nil;
}

- (void)setCanSend:(BOOL)canSend
{
    _canSend = canSend;
    BOOL show = canSend && !self.replayMode;
    self.inputBackground.hidden = !show;
    self.fieldBackground.hidden = !show;
    self.field.hidden = !show;
    self.emoteButton.hidden = !show;
    self.sendButton.hidden = !show;
    [self setNeedsLayout];
}

- (void)setSending:(BOOL)sending
{
    _sending = sending;
    self.sendButton.enabled = !sending;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.bounds;
    BOOL input = self.canSend && !self.replayMode;
    // (the emote picker takes the keyboard's place: its height arrives through the keyboard notifications)
    CGFloat bottomInset = self.keyboardOverlap;
    CGFloat inputH = input ? TWChatInputHeight : 0;
    CGFloat tableH = b.size.height - inputH - bottomInset;
    CGRect tableFrame = CGRectMake(0, 0, b.size.width, MAX(tableH, 0));
    BOOL widthChanged = fabs(self.tableView.frame.size.width - tableFrame.size.width) > 0.5;
    if (!CGRectEqualToRect(self.tableView.frame, tableFrame)) self.tableView.frame = tableFrame;
    if (widthChanged) [self invalidateLayouts];
    CGFloat y = CGRectGetMaxY(tableFrame);
    self.inputBackground.frame = CGRectMake(0, y, b.size.width, inputH);
    self.emoteButton.frame = CGRectMake(4, y + 7, 30, 30);
    CGFloat sendW = 58;
    self.sendButton.frame = CGRectMake(b.size.width - 6 - sendW, y + 7, sendW, 30);
    CGFloat fieldX = 38;
    self.fieldBackground.frame = CGRectMake(fieldX, y + 7, b.size.width - fieldX - sendW - 12, 30);
    self.field.frame = CGRectInset(self.fieldBackground.frame, 8, 0);
    CGSize pill = [self.moreMessagesButton.currentTitle sizeWithFont:self.moreMessagesButton.titleLabel.font];
    self.moreMessagesButton.frame = CGRectMake(floor((b.size.width - pill.width - 24) / 2), CGRectGetMaxY(tableFrame) - 32, pill.width + 24, 24);
}

#pragma mark - Messages

- (void)appendMessages:(NSArray *)messages
{
    if (!messages.count) return;
    TWChatStyle *style = [self currentStyle];
    for (TWChatMessage *m in messages) [TWChatLayout cachedLayoutForMessage:m style:style];
    [self.messages addObjectsFromArray:messages];
    if (self.messages.count > TWChatMaxMessages) {
        [self.messages removeObjectsInRange:NSMakeRange(0, self.messages.count - TWChatTrimTo)];
    }
    if (self.stuckToBottom) {
        [self.tableView reloadData];
        [self scrollToBottom];
    } else {
        // keep what the user is reading where it is
        // (rows are only added below what the user is reading, so the offset stays; when the oldest rows were
        // trimmed at the top the content moves a little, which is corrected by the next scroll)
        [self.tableView reloadData];
        self.unseen += messages.count;
        [self updateNewMessagesButton];
    }
}

- (void)appendNotice:(NSString *)text
{
    [self appendMessages:@[ [TWChatMessage noticeWithText:text] ]];
}

- (void)clearMessagesOfUser:(NSString *)login seconds:(NSInteger)seconds
{
    NSString *notice;
    if (!login.length) {
        for (TWChatMessage *m in self.messages) if (m.kind == TWChatKindMessage) { m.isDeleted = YES; m.layout = nil; }
        notice = L(@"The chat was cleared by a moderator.");
    } else {
        for (TWChatMessage *m in self.messages) if ([m.login isEqualToString:login]) { m.isDeleted = YES; m.layout = nil; }
        if (seconds > 0) notice = [NSString stringWithFormat:L(@"%@ was timed out for %@."), login, [TWUtils formatDuration:seconds]];
        else notice = [NSString stringWithFormat:L(@"%@ was banned."), login];
    }
    [self appendNotice:notice];
}

- (void)deleteMessageWithId:(NSString *)messageId
{
    for (TWChatMessage *m in self.messages) {
        if ([m.messageId isEqualToString:messageId]) { m.isDeleted = YES; m.layout = nil; }
    }
    [self.tableView reloadData];
}

- (void)removeAllMessages
{
    [self.messages removeAllObjects];
    self.unseen = 0;
    [self.tableView reloadData];
    [self updateNewMessagesButton];
}

- (void)scrollToBottom
{
    NSInteger n = (NSInteger)self.messages.count;
    if (n <= 0) return;
    [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:n - 1 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
    self.stuckToBottom = YES;
    self.unseen = 0;
    [self updateNewMessagesButton];
}

- (void)updateNewMessagesButton
{
    if (self.stuckToBottom || !self.unseen) {
        self.moreMessagesButton.hidden = YES;
        return;
    }
    [self.moreMessagesButton setTitle:[NSString stringWithFormat:L(@"%lu new messages ↓"), (unsigned long)self.unseen] forState:UIControlStateNormal];
    self.moreMessagesButton.hidden = NO;
    [self setNeedsLayout];
}

- (void)moreMessagesTapped
{
    [self scrollToBottom];
}

- (void)imageLoaded:(NSNotification *)note
{
    // the cell showing this image gets it; the others keep their layouts
    NSString *url = note.userInfo[@"url"];
    for (TWChatCell *cell in self.tableView.visibleCells) {
        for (TWChatImageSlot *slot in cell.layout.imageSlots) {
            if ([slot.url isEqualToString:url]) { [cell refreshImages]; break; }
        }
    }
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.messages.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TWChatMessage *m = self.messages[(NSUInteger)indexPath.row];
    TWChatLayout *layout = [TWChatLayout cachedLayoutForMessage:m style:[self currentStyle]];
    return ceil(layout.height) + 2 * TWChatCellPadV;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    TWChatCell *cell = [tableView dequeueReusableCellWithIdentifier:[TWChatCell reuseIdentifier] forIndexPath:indexPath];
    TWChatMessage *m = self.messages[(NSUInteger)indexPath.row];
    TWChatStyle *style = [self currentStyle];
    [cell configureWithMessage:m layout:[TWChatLayout cachedLayoutForMessage:m style:style] style:style alternate:NO];
    return cell;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGFloat bottom = scrollView.contentOffset.y + scrollView.bounds.size.height;
    BOOL atBottom = bottom >= scrollView.contentSize.height - 30;
    if (atBottom != self.stuckToBottom) {
        self.stuckToBottom = atBottom;
        if (atBottom) self.unseen = 0;
        [self updateNewMessagesButton];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    if (self.keyboardVisible) [self dismissKeyboard];
}

#pragma mark - Taps

- (TWChatCell *)cellAtGesture:(UIGestureRecognizer *)gesture point:(CGPoint *)pointInCell
{
    CGPoint p = [gesture locationInView:self.tableView];
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:p];
    if (!ip) return nil;
    TWChatCell *cell = (TWChatCell *)[self.tableView cellForRowAtIndexPath:ip];
    if (pointInCell) *pointInCell = [gesture locationInView:cell.contentView];
    return cell;
}

- (void)tableTapped:(UITapGestureRecognizer *)gesture
{
    if (self.keyboardVisible || self.pickerShown) { [self dismissKeyboard]; return; }
    CGPoint p;
    TWChatCell *cell = [self cellAtGesture:gesture point:&p];
    if (!cell || !cell.message.login.length) return;
    CGPoint inLayout = CGPointMake(p.x - TWChatCellPadH, p.y - TWChatCellPadV);
    TWChatLink *link = [cell.layout linkAtPoint:inLayout];
    if (link) {
        self.tappedLink = link.url;
        self.tappedMessage = cell.message;
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:link.url delegate:self cancelButtonTitle:L(@"Cancel") destructiveButtonTitle:nil otherButtonTitles:L(@"Open Link"), L(@"Copy Link"), nil];
        sheet.tag = 2;
        [sheet showInView:self];
        return;
    }
    if ([cell.layout isNameAtPoint:inLayout]) {
        [self showActionsForMessage:cell.message];
    }
}

- (void)tablePressed:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    TWChatCell *cell = [self cellAtGesture:gesture point:NULL];
    if (!cell || !cell.message.login.length) return;
    [self showActionsForMessage:cell.message];
}

- (void)showActionsForMessage:(TWChatMessage *)message
{
    self.tappedMessage = message;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[message nameForDisplay] delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Open Channel")];
    if (self.canSend && !self.replayMode) [sheet addButtonWithTitle:L(@"Mention")];
    [sheet addButtonWithTitle:L(@"Copy Message")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    sheet.tag = 1;
    [sheet showInView:self];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex < 0 || buttonIndex == actionSheet.cancelButtonIndex) return;
    NSString *title = [actionSheet buttonTitleAtIndex:buttonIndex];
    TWChatMessage *m = self.tappedMessage;
    if (actionSheet.tag == 2) {
        if ([title isEqualToString:L(@"Open Link")]) {
            if ([self.delegate respondsToSelector:@selector(chatView:didTapLink:)]) [self.delegate chatView:self didTapLink:self.tappedLink];
        } else {
            [UIPasteboard generalPasteboard].string = self.tappedLink ?: @"";
        }
        return;
    }
    if ([title isEqualToString:L(@"Open Channel")]) {
        if ([self.delegate respondsToSelector:@selector(chatView:didTapName:displayName:)]) [self.delegate chatView:self didTapName:m.login displayName:m.displayName];
    } else if ([title isEqualToString:L(@"Mention")]) {
        [self insertMention:m.displayName ?: m.login];
    } else if ([title isEqualToString:L(@"Copy Message")]) {
        [UIPasteboard generalPasteboard].string = m.text.length ? m.text : (m.systemText ?: @"");
    }
}

#pragma mark - Input

- (void)insertMention:(NSString *)name
{
    if (!name.length || !self.canSend) return;
    NSString *current = self.field.text ?: @"";
    NSString *mention = [NSString stringWithFormat:@"@%@ ", name];
    if (current.length && ![current hasSuffix:@" "]) current = [current stringByAppendingString:@" "];
    self.field.text = [current stringByAppendingString:mention];
    [self.field becomeFirstResponder];
}

- (void)insertText:(NSString *)text
{
    NSString *current = self.field.text ?: @"";
    if (current.length && ![current hasSuffix:@" "]) current = [current stringByAppendingString:@" "];
    self.field.text = [[current stringByAppendingString:text] stringByAppendingString:@" "];
}

- (void)clearInput
{
    self.field.text = @"";
}

- (void)sendTapped
{
    NSString *text = [self.field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || self.sending) return;
    if ([self.delegate respondsToSelector:@selector(chatView:wantsToSend:)]) [self.delegate chatView:self wantsToSend:text];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self sendTapped];
    return NO;
}

- (void)emoteTapped
{
    if (!self.picker) {
        // (an input view: UIKit shows it where the keyboard goes, and the keyboard notifications report its frame)
        self.picker = [[TWEmotePickerView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, [TWEmotePickerView preferredHeight])];
        self.picker.delegate = self;
    }
    if (self.pickerShown) {
        // back to the keyboard
        self.field.inputView = nil;
        self.pickerShown = NO;
        [self.field reloadInputViews];
        [self.field becomeFirstResponder];
    } else {
        [self.picker reloadWithChannelId:self.channelId];
        self.field.inputView = self.picker;
        self.pickerShown = YES;
        if (self.field.isFirstResponder) [self.field reloadInputViews];
        else [self.field becomeFirstResponder];
    }
}

- (void)emotePicker:(TWEmotePickerView *)picker didPickEmote:(TWEmote *)emote
{
    [self insertText:emote.name];
}

- (void)dismissKeyboard
{
    [self.field resignFirstResponder];
    if (self.pickerShown) {
        self.pickerShown = NO;
        self.field.inputView = nil;
        [self setNeedsLayout];
    }
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)note
{
    if (!self.field.isFirstResponder) return;
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inSelf = [self convertRect:end fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.bounds) - CGRectGetMinY(inSelf);
    if (overlap < 0 || overlap > self.bounds.size.height) overlap = 0;
    [self animateKeyboardTo:overlap info:note.userInfo];
}

- (void)keyboardWillHide:(NSNotification *)note
{
    [self animateKeyboardTo:0 info:note.userInfo];
}

- (void)animateKeyboardTo:(CGFloat)overlap info:(NSDictionary *)info
{
    BOOL visible = overlap > 0;
    if (fabs(overlap - self.keyboardOverlap) < 0.5 && visible == self.keyboardVisible) return;
    self.keyboardOverlap = overlap;
    self.keyboardVisible = visible;
    if (!visible) {
        self.pickerShown = NO;
        self.field.inputView = nil;
    }
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    BOOL wasBottom = self.stuckToBottom;
    [UIView animateWithDuration:duration delay:0 options:(UIViewAnimationOptions)(curve << 16) animations:^{
        [self layoutSubviews];
        if (wasBottom) [self scrollToBottom];
    } completion:nil];
    if ([self.delegate respondsToSelector:@selector(chatViewDidChangeKeyboard:visible:)]) [self.delegate chatViewDidChangeKeyboard:self visible:visible];
}

@end
