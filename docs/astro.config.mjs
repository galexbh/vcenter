// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	telemetry: false,
	// Rutas anteriores a la reorganización de la documentación (v1.2).
	redirects: {
		'/inicio/casos-de-uso': '/introduccion/casos-de-uso/',
	},
	integrations: [
		starlight({
			title: 'Plataforma vSphere · govc',
			description:
				'Guía de operación, auditoría y gobierno de VMware vCenter con govc y Claude Code: consultas controladas, reportes, auditorías y provisión con aprobación.',
			logo: {
				light: './src/assets/logo-light.svg',
				dark: './src/assets/logo-dark.svg',
				alt: 'Plataforma vSphere · govc',
			},
			favicon: '/favicon.svg',
			defaultLocale: 'root',
			locales: {
				root: { label: 'Español', lang: 'es' },
			},
			head: [
				// Documentación interna: fuera de buscadores.
				{ tag: 'meta', attrs: { name: 'robots', content: 'noindex, nofollow' } },
			],
			customCss: [
				'@fontsource-variable/inter',
				'@fontsource-variable/jetbrains-mono',
				'./src/styles/custom.css',
			],
			tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
			lastUpdated: false,
			pagination: true,
			sidebar: [
				{ label: 'Introducción', items: [{ autogenerate: { directory: 'introduccion' } }] },
				{ label: 'Puesta en marcha', items: [{ autogenerate: { directory: 'inicio' } }] },
				{ label: 'Seguridad y gobierno', items: [{ autogenerate: { directory: 'seguridad' } }] },
				{ label: 'Operación', items: [{ autogenerate: { directory: 'uso' } }] },
				{ label: 'Reportes y análisis', items: [{ autogenerate: { directory: 'reportes' } }] },
				{ label: 'Auditoría', items: [{ autogenerate: { directory: 'auditoria' } }] },
				{ label: 'Provisión', items: [{ autogenerate: { directory: 'provision' } }] },
				{ label: 'Referencia', items: [{ autogenerate: { directory: 'referencia' } }] },
			],
		}),
	],
});
