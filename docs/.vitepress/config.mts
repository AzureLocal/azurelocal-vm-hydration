import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-vm-hydration/',
  title: "Azure Local VM Hydration",
  description: "Governed centrally by HCS Platform Engineering standards",
  themeConfig: {
    logo: '/assets/images/azurelocal-vm-hydration-icon.svg',
    nav: [{"link":"/","text":"Home"},{"link":"/getting-started","text":"Getting Started"},{"link":"/module","text":"Module Reference"},{"link":"/roadmap","text":"Roadmap"},{"link":"/contributing","text":"Contributing"}],
    sidebar: [{"link":"/","text":"Home"},{"link":"/getting-started","text":"Getting Started"},{"link":"/module","text":"Module Reference"},{"link":"/roadmap","text":"Roadmap"},{"link":"/contributing","text":"Contributing"}],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-vm-hydration' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})




