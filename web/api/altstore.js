// AltStore source for SpotVault (iPhone).
// Served at /altstore.json (see vercel.json). Built live from the GitHub
// releases: only approved releases (not drafts, not pre-releases) are listed,
// so approving a version in the admin panel updates iPhone users too.
// AltStore users add the source once and get one-tap updates.

const REPO = 'sarathlal-12/spotvault';
const SITE = 'https://spotvault-web.vercel.app';
const TINT = '8B5CF6';

const APP = {
  name: 'SpotVault',
  bundleIdentifier: 'com.spotvault.app.spotvaultMobile',
  developerName: 'Sarath Lal',
  subtitle: 'Your playlists, offline.',
  localizedDescription:
    'SpotVault plays your music offline. Copy your playlists from the SpotVault app on your PC over Wi-Fi, ' +
    'and add new songs by search: your PC downloads them and sends them to the phone. ' +
    'Liked Songs, shuffle, repeat, queue editing, sleep timer and lock-screen controls.',
  iconURL: `${SITE}/logo.png`,
  tintColor: TINT,
  category: 'entertainment',
  screenshots: [],
  appPermissions: {
    entitlements: [],
    privacy: {
      NSLocalNetworkUsageDescription:
        'SpotVault connects to the SpotVault app on your PC over Wi-Fi to copy your playlists.',
    },
  },
};

// Pure function so it can be tested without the network.
function buildSource(releases) {
  const versions = [];
  for (const r of releases || []) {
    if (r.draft || r.prerelease) continue;
    const ipa = (r.assets || []).find((a) => /\.ipa$/i.test(a.name || ''));
    if (!ipa) continue;
    versions.push({
      version: String(r.tag_name || '').replace(/^v/i, ''),
      date: r.published_at || r.created_at,
      localizedDescription: (r.body || '').trim() || 'Improvements and fixes.',
      downloadURL: ipa.browser_download_url,
      size: ipa.size,
      minOSVersion: '15.0',
    });
  }
  // Newest first, by version number.
  const key = (v) => (v.match(/\d+/g) || []).slice(0, 3).map(Number).concat([0, 0, 0]).slice(0, 3);
  versions.sort((a, b) => {
    const x = key(a.version), y = key(b.version);
    for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return y[i] - x[i];
    return 0;
  });
  return {
    name: 'SpotVault',
    identifier: 'app.vercel.spotvault-web.source',
    subtitle: 'Offline music from your PC',
    description: 'Official source for the SpotVault iPhone app.',
    iconURL: `${SITE}/logo.png`,
    website: SITE,
    tintColor: TINT,
    apps: [{ ...APP, versions }],
    news: [],
  };
}

async function handler(req, res) {
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=30`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'SpotVault-AltStore-Source' },
    });
    if (!r.ok) throw new Error('GitHub answered ' + r.status);
    const body = JSON.stringify(buildSource(await r.json()), null, 2);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    // Cache at the edge for 10 minutes; keep serving the last copy if GitHub is down.
    res.setHeader('Cache-Control', 'public, s-maxage=600, stale-while-revalidate=86400, stale-if-error=604800');
    res.statusCode = 200;
    res.end(body);
  } catch (e) {
    res.statusCode = 502;
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.end(JSON.stringify({ error: 'Source temporarily unavailable' }));
  }
}

module.exports = handler;
module.exports.buildSource = buildSource;
