from django.test import Client, TestCase


class HomePageTests(TestCase):
    def test_home_page_loads(self):
        response = Client().get("/")
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Ask for a plot in plain language")
