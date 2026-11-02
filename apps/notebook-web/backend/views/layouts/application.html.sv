<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <link rel="icon" href="/favicon.svg" type="image/svg+xml">
    <title>#{title}</title>
    #{json_script(bootstrap, id: "notebook-bootstrap")}
    #{assets.tags()}
  </head>
  <body>
    <main>#{content}</main>
  </body>
</html>
