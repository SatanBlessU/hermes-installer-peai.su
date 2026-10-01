# 🚀 Hermes Agent & Hermes WebUI 1-Click Provisioner

Высокоскоростной полностью автоматизированный скрипт установки **Hermes Agent** и **Hermes WebUI** для серверов Ubuntu/Debian. Предназначен как для ручной установки одной командой, так и для интеграции в бэкенд-сервисы продажи и авто-провижининга VPS.

---

## ⚡ Особенности
- **Zero-touch автоматизация:** Никаких интерактивных окон, мастеров настройки или ручных подтверждений.
- **Поддержка кастомного провайдера `https://api.peai.su/v1`:** Автоматическое подключение всех моделей (`deepseek-v4-flash`, `gemini`, `claude`, `grok` и др.).
- **Многоуровневая привязка API-ключа:** Запись в `HERMES_CUSTOM_API_PEAI_SU_API_KEY`, `CUSTOM_API_KEY`, `OPENAI_API_KEY` и `config.yaml`.
- **Автозапуск Systemd:** Автоматическое создание и включение службы `hermes-webui.service`.
- **Поддержка бэкенд-протокола (`--json`):** Возврат структурированного JSON-ответа с IP, портом, статусом сервиса и URL для личного кабинета пользователя.

---

## 🛠 Установка одной командой

### 1. С указанием API-ключа PEAI:
```bash
curl -fsSL https://raw.githubusercontent.com/SatanBlessU/hermes-installer-peai.su/main/install.sh | sudo bash -s -- --apikeypeai "sk-ai-ваш_ключ"
```

### 2. С пустым API-ключом (клиент введет сам позже):
```bash
curl -fsSL https://raw.githubusercontent.com/SatanBlessU/hermes-installer-peai.su/main/install.sh | sudo bash
```

### 3. Для авто-провижининга из бэкенда (JSON output):
```bash
curl -fsSL https://raw.githubusercontent.com/SatanBlessU/hermes-installer-peai.su/main/install.sh | sudo bash -s -- --apikeypeai "sk-ai-..." --json
```

**Пример JSON-ответа:**
```json
{
  "status": "success",
  "webui_url": "http://31.76.20.96:8787",
  "server_ip": "31.76.20.96",
  "port": 8787,
  "service_status": "active",
  "autostart_enabled": "enabled",
  "provider": "https://api.peai.su/v1",
  "default_model": "ds/deepseek-v4-flash",
  "api_key_configured": true
}
```

---

## 🧹 Полное удаление (Clean Reset)
```bash
curl -fsSL https://raw.githubusercontent.com/SatanBlessU/hermes-installer-peai.su/main/uninstall.sh | sudo bash
```

---

## 🤖 Интеграция в сервис продажи VPS (Архитектура и протокол)

### Схема работы (Workflow):
1. Клиент оплачивает VPS на вашем сайте.
2. Ваш бэкенд (Python/Node.js/Go) подключается к купленному серверу по SSH и выполняет:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/SatanBlessU/hermes-installer-peai.su/main/install.sh | sudo bash -s -- --apikeypeai "sk-ai-user-token" --json
   ```
3. Бэкенд парсит JSON из stdout, получает поле `"webui_url"` (например, `http://1.2.3.4:8787`).
4. Клиенту в личном кабинете или в Telegram-боте мгновенно выдается готовая ссылка на веб-панель.
