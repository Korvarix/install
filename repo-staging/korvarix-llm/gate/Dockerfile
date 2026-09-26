# korvarix-llm gate - korvarix.com SSO + avatar bridge for Open WebUI.
# Zero-dependency Node app; the image only adds the runtime.
FROM node:22-alpine
WORKDIR /gate
# gate sources + the vendored shared env lib
COPY gate/gate.js gate/gate.js
COPY lib lib
ENV NODE_ENV=production
# the gate reads its real config from --env-file at runtime
EXPOSE 8211
USER node
CMD ["node", "gate/gate.js"]