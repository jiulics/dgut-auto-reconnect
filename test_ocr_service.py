import unittest
import importlib.util
from pathlib import Path

class ServiceTests(unittest.TestCase):
    def test_service_exists(self):
        self.assertTrue(Path(__file__).with_name('ocr_service.py').exists(), 'local OCR service missing')

    def test_attempt_budget(self):
        from ocr_service import AttemptBudget
        b = AttemptBudget()
        self.assertTrue(b.claim(1000))
        self.assertFalse(b.claim(1001))
        self.assertTrue(b.claim(1030))
        self.assertTrue(b.claim(1090))
        self.assertFalse(b.claim(1210))
        self.assertTrue(b.claim(1991))

    def test_reset_after_online(self):
        from ocr_service import AttemptBudget
        b = AttemptBudget()
        b.claim(1000)
        b.reset()
        self.assertTrue(b.claim(1001))

    def test_validate_digits(self):
        from ocr_service import validate_code
        self.assertEqual(validate_code('1234'), '1234')
        for value in ['12O4','123','12345','１２３４','<html>']:
            with self.assertRaises(ValueError): validate_code(value)

    def test_image_limits(self):
        from ocr_service import decode_image
        for value in ['', 'file:///secret', 'data:image/png;base64,!!!!', 'a'*300000]:
            with self.assertRaises(ValueError): decode_image(value)

if __name__ == '__main__': unittest.main()
