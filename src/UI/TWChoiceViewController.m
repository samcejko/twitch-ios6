#import "TWChoiceViewController.h"
#import "TWTheme.h"
#import "TWCommon.h"

@implementation TWChoiceViewController

- (instancetype)init
{
    return [super initWithStyle:UITableViewStyleGrouped];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [[TWTheme shared] applyToTableView:self.tableView];
    [[TWTheme shared] applyToNavigationBar:self.navigationController.navigationBar];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL subtitle = (NSUInteger)indexPath.row < self.subtitles.count && [self.subtitles[(NSUInteger)indexPath.row] length];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:subtitle ? UITableViewCellStyleSubtitle : UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = self.titles[(NSUInteger)indexPath.row];
    if (subtitle) {
        cell.detailTextLabel.text = self.subtitles[(NSUInteger)indexPath.row];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.numberOfLines = 2;
    }
    cell.accessoryType = indexPath.row == self.selectedIndex ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    [[TWTheme shared] styleCell:cell];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    BOOL subtitle = (NSUInteger)indexPath.row < self.subtitles.count && [self.subtitles[(NSUInteger)indexPath.row] length];
    return subtitle ? 56 : 44;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    self.selectedIndex = indexPath.row;
    [tableView reloadData];
    if (self.completion) self.completion(indexPath.row);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface TWTextEntryViewController () <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UIImageView *fieldBackground;
@property (nonatomic, strong) UILabel *explanationLabel;
@end

@implementation TWTextEntryViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    TWTheme *t = [TWTheme shared];
    self.view.backgroundColor = [t backgroundColor];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveTapped)];
    self.fieldBackground = [[UIImageView alloc] initWithImage:[t textFieldBackgroundImage]];
    [self.view addSubview:self.fieldBackground];
    self.field = [[UITextField alloc] initWithFrame:CGRectZero];
    self.field.text = self.text;
    self.field.placeholder = self.placeholder;
    self.field.font = [UIFont systemFontOfSize:16];
    self.field.textColor = [t inputTextColor];
    self.field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.field.autocorrectionType = UITextAutocorrectionTypeNo;
    self.field.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.field.returnKeyType = UIReturnKeyDone;
    self.field.delegate = self;
    self.field.keyboardAppearance = t.isDark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    [self.view addSubview:self.field];
    self.explanationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.explanationLabel.backgroundColor = [UIColor clearColor];
    self.explanationLabel.numberOfLines = 0;
    self.explanationLabel.font = [UIFont systemFontOfSize:13];
    self.explanationLabel.textColor = [t secondaryTextColor];
    self.explanationLabel.text = self.explanation;
    [self.view addSubview:self.explanationLabel];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.field becomeFirstResponder];
}

- (void)viewWillLayoutSubviews
{
    [super viewWillLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat w = MIN(b.size.width - 32, 500);
    CGFloat x = floor((b.size.width - w) / 2);
    self.fieldBackground.frame = CGRectMake(x, 20, w, 40);
    self.field.frame = CGRectMake(x + 10, 20, w - 20, 40);
    self.explanationLabel.frame = CGRectMake(x, 70, w, 120);
}

- (void)saveTapped
{
    if (self.completion) self.completion(self.field.text ?: @"");
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self saveTapped];
    return YES;
}

@end
