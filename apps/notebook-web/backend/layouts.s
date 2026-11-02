package layouts

from orbit.html import json_script

export application

template "./views/layouts/application.html.sv"
def application(content, title:, assets:, bootstrap:)
