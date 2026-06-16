import type { Config } from 'tailwindcss'

export default {
  content: [
    './index.html',
    './src/**/*.{ts,tsx}',
  ],
  theme: {
    extend: {
      colors: {
        forest: {
          50:  '#f0faf0',
          100: '#dcf5dc',
          200: '#b9eab9',
          300: '#86d886',
          400: '#4ebe4e',
          500: '#2da02d',
          600: '#1f7f1f',
          700: '#1a661a',
          800: '#175217',
          900: '#144314',
        },
        bark: {
          50:  '#fdf8f0',
          100: '#faeedd',
          200: '#f4d9b5',
          300: '#ecbf82',
          400: '#e39f4d',
          500: '#d9842a',
          600: '#c06b1e',
          700: '#9f521a',
          800: '#81421b',
          900: '#6a3819',
        },
      },
      fontFamily: {
        sans: ['Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'Fira Code', 'monospace'],
      },
    },
  },
  plugins: [],
} satisfies Config
