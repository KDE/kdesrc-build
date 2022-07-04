#!/usr/bin/env perl

use v5.28;

eval {
    use Mojolicious::Lite;
};

if ($@) {
    say <<EOF
Mojolicious::Lite and Mojolicious::Plugin::PODViewer must be installed (e.g.
using CPAN-Minus) to use this script.
EOF
}

# Add this directory and the kdesrc-build Perl modules so that they will be
# found by the Pod::Simple search algorithm
push @INC, '.', '../../modules';

plugin 'PODViewer', {
    default_module => 'ksb',
    layout => 'default',
    route => app->routes->any('/'),
};

#push @{app->static->paths}, './static';

say "Once the daemon has started, try opening links like:";
say "\thttp://localhost:3000/perl-upgrade-notes or";
say "\thttp://localhost:3000/ksb";

push @ARGV, 'daemon' unless @ARGV; # Default to daemon
app->start;

__DATA__
@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="/water-dark.css">
    <title><%= title %></title>
  <section class="section">
    <main class="container">
        %= content
    </main>
  </section>
</html>

@@ water-dark.css
/* From https://github.com/kognise/water.css release 2.1.1 (MIT license), stripped further */
body {
  font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Oxygen', 'Ubuntu', 'Cantarell', 'Fira Sans', 'Droid Sans', 'Helvetica Neue', sans-serif;
  line-height: 1.4;
  max-width: 800px;
  margin: 20px auto;
  padding: 0 10px;
  color: #dbdbdb;
  background: #202b38;
  text-rendering: optimizeLegibility;
}
button, input, textarea {
  transition: background-color 0.1s linear, border-color 0.1s linear, color 0.1s linear, box-shadow 0.1s linear, transform 0.1s ease;
}
h1 {
  font-size: 2.2em;
  margin-top: 0;
}
h1, h2, h3, h4, h5, h6 {
  margin-bottom: 12px;
}
h1, h2, h3, h4, h5, h6, strong {
  color: #ffffff;
}
h1, h2, h3, h4, h5, h6, b, strong, th {
  font-weight: 600;
}
blockquote {
  border-left: 4px solid #0096bfab;
  margin: 1.5em 0em;
  padding: 0.5em 1em;
  font-style: italic;
}
blockquote > footer {
  margin-top: 10px;
  font-style: normal;
}
blockquote cite {
  font-style: normal;
}
address {
  font-style: normal;
}
button, input[type='submit'], input[type='button'], input[type='checkbox'] {
  cursor: pointer;
}
input:not([type='checkbox']):not([type='radio']), select {
  display: block;
}
input, select, button, textarea {
  color: #ffffff;
  background-color: #161f27;
  font-family: inherit;
  font-size: inherit;
  margin-right: 6px;
  margin-bottom: 6px;
  padding: 10px;
  border: none;
  border-radius: 6px;
  outline: none;
}
input:not([type='checkbox']):not([type='radio']), select, button, textarea {
  -webkit-appearance: none;
}
textarea {
  margin-right: 0;
  width: 100%;
  box-sizing: border-box;
  resize: vertical;
}
button, input[type='submit'], input[type='button'] {
  padding-right: 30px;
  padding-left: 30px;
}
button:hover, input[type='submit']:hover, input[type='button']:hover {
  background: #324759;
}
input:focus, select:focus, button:focus, textarea:focus {
  box-shadow: 0 0 0 2px #0096bfab;
}
input[type='checkbox']:active, input[type='radio']:active, input[type='submit']:active, input[type='button']:active, button:active {
  transform: translateY(2px);
}
input:disabled, select:disabled, button:disabled, textarea:disabled {
  cursor: not-allowed;
  opacity: .5;
}
::placeholder {
  color: #a9a9a9;
}
a {
  text-decoration: none;
  color: #41adff;
}
a:hover {
  text-decoration: underline;
}
code, kbd {
  background: #161f27;
  color: #ffbe85;
  padding: 5px;
  border-radius: 6px;
}
pre > code {
  padding: 10px;
  display: block;
  overflow-x: auto;
}
img {
  max-width: 100%;
}
hr {
  border: none;
  border-top: 1px solid #dbdbdb;
}
table {
  border-collapse: collapse;
  margin-bottom: 10px;
  width: 100%;
}
td, th {
  padding: 6px;
  text-align: left;
}
th {
  border-bottom: 1px solid #dbdbdb;
}
tbody tr:nth-child(even) {
  background-color: #161f27;
}
/*# sourceMappingURL=dark.css.map */
