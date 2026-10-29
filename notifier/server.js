/*
 * notifier - second service metier du fil rouge.
 * Recoit un evenement "produit cree" de demo-api et logge une notification
 * (simulateur d'email / Slack). Il ne connait rien de l'API ni de la base.
 *
 * Variables d'environnement :
 *   PORT   port d'ecoute   (def: 4000)
 */

import express from 'express';

const PORT = Number(process.env.PORT || 4000);

const app = express();
app.use(express.json());

app.get('/health', (_req, res) => res.json({ status: 'UP' }));

app.post('/notify', (req, res) => {
  console.log(`[notifier] nouveau produit : ${JSON.stringify(req.body)}`);
  res.status(202).json({ received: true });
});

const server = app.listen(PORT, () => {
  console.log(`[notifier] started on port ${PORT}`);
});

// PID 1 dans le conteneur : arret propre sur SIGTERM (docker stop).
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
