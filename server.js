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

app.listen(PORT, "0.0.0.0", () => {
  console.log(`Server running on port ${PORT}`);
});
