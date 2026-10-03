// Build-time constants of the Twitch integration.
#import <Foundation/Foundation.h>

// Client ID of the Twitch application the login goes through: "Samcejko iOS6 Client", registered by samcejko at
// dev.twitch.tv/console/apps as a "Public" client, which is what the device code flow needs. It identifies the app,
// not a user, and is public by design: no secret is involved.
#define TWTwitchClientID @"cul1df7g9pymz07zrk0hluo57soluv"

// The public Client ID of twitch.tv's own web player. Browsing and playback need no account: they use the same
// GraphQL API as the website does for a visitor who is not logged in.
#define TWTwitchWebClientID @"kimne78kx3ncx6brgo4mv6wki5h1ko"

#define TWTwitchGQLURL @"https://gql.twitch.tv/gql"
#define TWTwitchUsherURL @"https://usher.ttvnw.net"
#define TWTwitchHelixURL @"https://api.twitch.tv/helix"
#define TWTwitchAuthURL @"https://id.twitch.tv/oauth2"

// What the login asks for: the followed channels, sending chat messages, the user's own emotes
#define TWTwitchScopes @"user:read:follows user:write:chat user:read:emotes chat:read chat:edit"
