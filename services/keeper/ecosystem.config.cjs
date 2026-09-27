// pm2 process file. Build first (`pnpm build`), then `pm2 start ecosystem.config.cjs`.
// The process reads ./.env itself, so pm2 does not need an env block.
module.exports = {
  apps: [
    {
      name: "vadium-keeper",
      script: "dist/main.js",
      cwd: __dirname,
      interpreter: "node",
      exec_mode: "fork",
      instances: 1,
      autorestart: true,
      restart_delay: 5000,
      max_restarts: 50,
      kill_timeout: 15000,
      time: true,
      env: { NODE_ENV: "production" },
    },
  ],
};
