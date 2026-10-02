#import <UIKit/UIKit.h>
#import "TWGQL.h"

typedef NS_ENUM(NSInteger, TWGridKind) {
    TWGridKindStreams = 0,     // TWStream items (TWChannel items are shown too: offline channels)
    TWGridKindGames,           // TWGame items
};

// Loads one page: cursor nil = the first page. Returns the task so that it can be cancelled.
typedef TWHTTPTask *(^TWGridLoader)(NSString *cursor, TWListCompletion completion);

// A paged grid of streams or categories with pull-to-refresh, "load more" at the bottom, an empty/error state and
// an optional header view that scrolls with the content (channel and category pages).
@interface TWGridViewController : UIViewController

- (instancetype)initWithKind:(TWGridKind)kind loader:(TWGridLoader)loader;

@property (nonatomic, copy) TWGridLoader loader;
@property (nonatomic, readonly, strong) UICollectionView *collectionView;
@property (nonatomic, readonly, strong) NSArray *items;
@property (nonatomic, copy) NSString *emptyText;          // shown when the first page is empty
@property (nonatomic) BOOL refreshesOnAppear;             // reload when the view appears after a while (default YES)
@property (nonatomic) NSTimeInterval staleAfter;          // seconds (default 120)

// A view above the grid, scrolling with it (its height is taken from its frame)
@property (nonatomic, strong) UIView *headerView;
- (void)setHeaderHeight:(CGFloat)height;

- (void)reload;                                           // from the first page
- (void)reloadKeepingItemsIfPossible;                     // after a settings change
- (void)replaceItems:(NSArray *)items;                    // show a fixed list (no paging)
- (void)applyTheme;

// Taps: default behaviour opens the stream / category; a block replaces it
@property (nonatomic, copy) void (^onSelectItem)(id item);

@end
