const express = require("express");

const app = express();

const PORT = process.env.PORT || 3000;

app.get("/", (req, res) => {
  res.send(`
    <html>
      <head>
        <title>Containerized AWS Application</title>
      </head>
      <body>
        <h1>Containerized Application</h1>
        <h2>Application is running successfully!</h2>
        <p>Deployed using Docker + Amazon ECR + Amazon ECS.</p>
      </body>
    </html>
  `);
});

app.get("/health", (req, res) => {
  res.json({ status: "ok" });
});

const server = app.listen(PORT, "0.0.0.0", () => {
  console.log(`Server running on port ${PORT}`);
});

// ECS sends SIGTERM when stopping a task; exit promptly instead of waiting
// for the 30-second SIGKILL timeout.
process.on("SIGTERM", () => {
  console.log("SIGTERM received, shutting down");
  server.close(() => process.exit(0));
});
