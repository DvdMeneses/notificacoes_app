# Notificador entre aparelhos (Flutter + Firebase + Node)

```
Celular A ──(código do grupo + deviceIds)──► Backend Node ──► FCM ──► Celular B, C...
     │                                           │
     └──── Firestore: groups/{código}/devices ◄──┘  (aparelhos do grupo + tokens)
```

Entrada discreta: o app abre uma **tela branca**. Toque **5 vezes** nela para
aparecer o campo de senha. A **senha é a chave do grupo** — digite a mesma
senha nos três celulares e eles aparecem na mesma lista. Cada aparelho se
registra sozinho com nome + token FCM. Quem envia marca os aparelhos na lista
e cada um recebe uma notificação separada, com resultado individual.

Por baixo o app usa login **anônimo** do Firebase (invisível, gratuito) só para
o backend recusar chamadas que não vêm do app. Trate o código do grupo como
senha.

## Custo: zero
Tudo cabe no plano **Spark** do Firebase (não pede cartão): Auth anônimo, FCM
(ilimitado) e Firestore (50 mil leituras / 20 mil gravações por dia). O
backend roda no seu PC ou no Render free (também sem cartão).

## 1. Firebase
1. Crie um projeto em https://console.firebase.google.com (fique no plano Spark).
2. **Authentication → Método de login** → ative **Anônimo**.
3. **Firestore Database** → criar banco → aba *Regras* → cole `firestore.rules`.
4. **Configurações do projeto → Contas de serviço** → *Gerar nova chave privada*
   → salve como `backend/service-account.json` (nunca coloque no app nem no git).

## 2. App Flutter
```bash
dart pub global activate flutterfire_cli
cd app
flutterfire configure        # gera lib/firebase_options.dart e google-services.json
flutter run
```
Na primeira abertura: toque 5 vezes na tela branca, digite a senha (de 8 a 32
letras/números, a mesma em todos os celulares) e dê um nome ao aparelho. Use a
engrenagem para colocar a URL do backend.

## 3. Backend
```bash
cd backend
cp .env.example .env         # ajuste o caminho do service-account.json
npm install
npm start                    # http://<IP-do-PC>:3000
```
- **No PC:** na mesma rede, use `http://<IP-do-PC>:3000`. Para redes
  diferentes use um túnel grátis: `cloudflared tunnel --url http://localhost:3000`.
- **Render (free):** novo *Web Service* com *Root Directory* `backend`,
  start `npm start`, variável `FIREBASE_SERVICE_ACCOUNT` = conteúdo do JSON
  em uma linha. O free "dorme" após 15 min; a 1ª requisição leva ~30-60 s.

## API
- `GET /health`
- `POST /send` — header `Authorization: Bearer <Firebase ID token>`,
  body `{ "groupCode": "...", "deviceIds": ["..."], "title": "...", "body": "..." }`
  → `{ "results": [{ "deviceId": "...", "ok": true }] }`
