import { defineConfig } from 'vitepress'

const repo = 'https://github.com/aiden0rchad/Waifu2x-Mac'
const site = 'https://aiden0rchad.github.io/Waifu2x-Mac'

export default defineConfig({
  title: 'Waifu2x-Mac',
  titleTemplate: ':title | Waifu2x-Mac Docs',
  description: 'Build, use, and troubleshoot the Apple Silicon upscaler for images, GIFs, and video.',
  base: '/Waifu2x-Mac/',
  appearance: 'dark',
  lastUpdated: true,
  sitemap: { hostname: `${site}/` },
  themeConfig: {
    logo: { src: '/assets/site-icon.png', alt: 'Waifu2x-Mac' },
    siteTitle: 'Waifu2x-Mac / docs',
    nav: [
      { text: 'Start here', link: '/start-here' },
      { text: 'Recipes', link: '/images' },
      { text: 'Builds & status', link: '/releases' },
    ],
    sidebar: [
      { text: 'Start here', items: [
        { text: 'Overview', link: '/' },
        { text: 'New to upscaling?', link: '/start-here' },
        { text: 'Build & first run', link: '/getting-started' },
        { text: 'Your first upscale', link: '/walkthrough' },
        { text: 'Builds & platform status', link: '/releases' },
      ] },
      { text: 'Use the app', items: [
        { text: 'Images & wallpapers', link: '/images' },
        { text: 'GIFs & video', link: '/motion' },
        { text: 'Engines & models', link: '/engines' },
        { text: 'Size, presets & output', link: '/settings' },
        { text: 'Advanced settings', link: '/advanced' },
      ] },
      { text: 'Help & reference', items: [
        { text: 'Troubleshooting', link: '/troubleshooting' },
        { text: 'FAQ & glossary', link: '/faq' },
        { text: 'Privacy, storage & updates', link: '/privacy' },
      ] },
      { text: 'Build & contribute', items: [
        { text: 'Development & tests', link: '/development' },
        { text: 'Architecture', link: '/architecture' },
        { text: 'Packaging & signing', link: '/packaging' },
      ] },
    ],
    search: { provider: 'local' },
    outline: { level: [2, 3], label: 'On this page' },
    editLink: { pattern: `${repo}/edit/main/docs/:path`, text: 'Improve this page on GitHub' },
    socialLinks: [{ icon: 'github', link: repo }],
    footer: { message: `Waifu2x-Mac · <a href="${repo}/blob/main/NOTICE.md">License notices</a>` },
  },
})
