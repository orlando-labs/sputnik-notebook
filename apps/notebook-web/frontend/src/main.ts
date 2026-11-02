import 'vite/modulepreload-polyfill'
import { createApp } from 'vue'
import App from './App.vue'
import { snapshot } from './api'
import './style.css'

const bootstrap = document.getElementById('notebook-bootstrap')
if (!bootstrap?.textContent) throw new Error('Notebook bootstrap data is missing')
createApp(App, { initial: snapshot(JSON.parse(bootstrap.textContent)) }).mount('#notebook-app')
