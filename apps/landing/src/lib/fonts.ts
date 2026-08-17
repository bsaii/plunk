import localFont from 'next/font/local';

// Self-hosted via @fontsource (latin, normal style) instead of next/font/google, whose Turbopack
// loader needs to reach fonts.googleapis.com/fonts.gstatic.com at build time — unavailable in some
// CI/Docker build environments and previously only masked by turbo's build cache never invalidating.
export const display = localFont({
  src: [
    {path: '../../../../node_modules/@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-400-normal.woff2', weight: '400', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-500-normal.woff2', weight: '500', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-600-normal.woff2', weight: '600', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-700-normal.woff2', weight: '700', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/bricolage-grotesque/files/bricolage-grotesque-latin-800-normal.woff2', weight: '800', style: 'normal'},
  ],
  variable: '--font-display',
  display: 'swap',
});

export const body = localFont({
  src: [
    {path: '../../../../node_modules/@fontsource/hanken-grotesk/files/hanken-grotesk-latin-400-normal.woff2', weight: '400', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/hanken-grotesk/files/hanken-grotesk-latin-500-normal.woff2', weight: '500', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/hanken-grotesk/files/hanken-grotesk-latin-600-normal.woff2', weight: '600', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/hanken-grotesk/files/hanken-grotesk-latin-700-normal.woff2', weight: '700', style: 'normal'},
  ],
  variable: '--font-body',
  display: 'swap',
});

export const mono = localFont({
  src: [
    {path: '../../../../node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-400-normal.woff2', weight: '400', style: 'normal'},
    {path: '../../../../node_modules/@fontsource/jetbrains-mono/files/jetbrains-mono-latin-500-normal.woff2', weight: '500', style: 'normal'},
  ],
  variable: '--font-mono',
  display: 'swap',
});
