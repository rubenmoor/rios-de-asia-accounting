from airbnb_books.web.app import create_app


def test_index():
    response = create_app().test_client().get("/")
    assert response.status_code == 200
    assert b"airbnb-books" in response.data
