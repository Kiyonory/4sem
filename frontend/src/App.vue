<script setup>
import { onMounted, ref } from 'vue'

const apiStatus = ref('проверка…')

onMounted(async () => {
  try {
    const res = await fetch('/api/health/')
    const data = await res.json()
    apiStatus.value = data.status === 'ok' ? 'Django отвечает' : 'неожиданный ответ'
  } catch {
    apiStatus.value = 'нет связи с Django (запустите runserver)'
  }
})
</script>

<template>
  <main class="app">
    <h1>Магазин — Vue</h1>
    <p class="lead">
      Фронтенд для будущих лабораторных. Код: <code>frontend/src/</code>
    </p>
    <p class="status">API: {{ apiStatus }}</p>
    <p class="hint">
      <a href="/admin/">Админка Django</a>
    </p>
  </main>
</template>

<style scoped>
.app {
  max-width: 40rem;
  margin: 0 auto;
  padding: 2rem 1.25rem;
}

.lead {
  color: #444;
  line-height: 1.5;
}

.status {
  padding: 0.75rem 1rem;
  border-radius: 8px;
  background: #f0f4ff;
  border: 1px solid #c5d4ff;
}

.hint {
  margin-top: 2rem;
  font-size: 0.95rem;
}

.hint a {
  color: #1a56db;
}
</style>
