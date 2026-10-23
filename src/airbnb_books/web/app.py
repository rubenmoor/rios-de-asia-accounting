from flask import Flask, render_template

from airbnb_books import __version__


def create_app() -> Flask:
    app = Flask(__name__)

    @app.route("/")
    def index() -> str:
        return render_template("index.html", version=__version__)

    return app
