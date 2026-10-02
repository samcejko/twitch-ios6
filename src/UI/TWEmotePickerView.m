#import "TWEmotePickerView.h"
#import "TWImageLoader.h"
#import "TWTheme.h"
#import "TWUtils.h"
#import "TWCommon.h"

static NSString * const kEmoteCellId = @"emote";
static NSString * const kHeaderId = @"header";

@interface TWEmotePickerCell : UICollectionViewCell
@property (nonatomic, strong) TWImageView *imageView;
@end

@implementation TWEmotePickerCell
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _imageView = [[TWImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.maxPixels = 128;
        [self.contentView addSubview:_imageView];
    }
    return self;
}
- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    self.contentView.backgroundColor = highlighted ? [UIColor colorWithWhite:0.5 alpha:0.3] : [UIColor clearColor];
}
@end

@interface TWEmotePickerHeader : UICollectionReusableView
@property (nonatomic, strong) UILabel *label;
@end

@implementation TWEmotePickerHeader
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _label = [[UILabel alloc] initWithFrame:CGRectInset(self.bounds, 8, 0)];
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _label.backgroundColor = [UIColor clearColor];
        _label.font = [UIFont boldSystemFontOfSize:12];
        [self addSubview:_label];
    }
    return self;
}
@end

@interface TWEmotePickerView () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray *sections;     // @{ title, emotes }
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, copy) NSString *channelIdForReload;
@end

@implementation TWEmotePickerView

+ (CGFloat)preferredHeight
{
    return TWIsPad() ? 264 : 216;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.itemSize = CGSizeMake(40, 40);
        layout.minimumInteritemSpacing = 2;
        layout.minimumLineSpacing = 2;
        layout.sectionInset = UIEdgeInsetsMake(2, 6, 8, 6);
        layout.headerReferenceSize = CGSizeMake(frame.size.width, 22);
        _collectionView = [[UICollectionView alloc] initWithFrame:self.bounds collectionViewLayout:layout];
        _collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _collectionView.dataSource = self;
        _collectionView.delegate = self;
        _collectionView.alwaysBounceVertical = YES;
        [_collectionView registerClass:[TWEmotePickerCell class] forCellWithReuseIdentifier:kEmoteCellId];
        [_collectionView registerClass:[TWEmotePickerHeader class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:kHeaderId];
        [self addSubview:_collectionView];
        _emptyLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.bounds, 20, 20)];
        _emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _emptyLabel.backgroundColor = [UIColor clearColor];
        _emptyLabel.numberOfLines = 0;
        _emptyLabel.textAlignment = NSTextAlignmentCenter;
        _emptyLabel.font = [UIFont systemFontOfSize:14];
        _emptyLabel.text = L(@"No emotes loaded yet.");
        _emptyLabel.hidden = YES;
        [self addSubview:_emptyLabel];
        [self applyTheme];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(emotesChanged) name:TWEmotesDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme
{
    TWTheme *t = [TWTheme shared];
    self.backgroundColor = t.isDark ? [UIColor colorWithWhite:0.1 alpha:1] : [UIColor colorWithWhite:0.82 alpha:1];
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.emptyLabel.textColor = [t secondaryTextColor];
    [self.collectionView reloadData];
}

- (void)reloadWithChannelId:(NSString *)channelId
{
    self.channelIdForReload = channelId;
    self.sections = [[TWEmoteStore shared] pickerSectionsForChannelId:channelId];
    self.emptyLabel.hidden = self.sections.count > 0;
    [self.collectionView reloadData];
}

- (void)emotesChanged
{
    if (self.window) [self reloadWithChannelId:self.channelIdForReload];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return (NSInteger)self.sections.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return (NSInteger)[self.sections[(NSUInteger)section][@"emotes"] count];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    TWEmotePickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kEmoteCellId forIndexPath:indexPath];
    TWEmote *emote = self.sections[(NSUInteger)indexPath.section][@"emotes"][(NSUInteger)indexPath.item];
    [cell.imageView setImageURL:[emote urlForScale:[TWUtils screenScale]] placeholder:nil];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    TWEmotePickerHeader *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:kHeaderId forIndexPath:indexPath];
    header.label.text = self.sections[(NSUInteger)indexPath.section][@"title"];
    header.label.textColor = [[TWTheme shared] secondaryTextColor];
    return header;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    TWEmote *emote = self.sections[(NSUInteger)indexPath.section][@"emotes"][(NSUInteger)indexPath.item];
    [self.delegate emotePicker:self didPickEmote:emote];
}

@end
