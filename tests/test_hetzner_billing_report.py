import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('billing',Path(__file__).resolve().parents[1]/'scripts/hetzner_billing_report.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
class ActualUsageTests(unittest.TestCase):
    def source(self):
        return dict(source='https://console.hetzner.com/usage',period='2026-10',captured_at='2026-10-18T12:00:00Z',currency='EUR',total='1.25',vat_rate='0',projects=[dict(name='project',amount='1.25')])
    def test_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp);b.write_report(self.source(),out)
            self.assertEqual(json.loads((out/'billing.json').read_text())['rows'][0]['consumption'],'1.25')
            self.assertNotIn('__BILLING_DATA__',(out/'index.html').read_text())
    def test_rejects_wrong_total(self):
        source=self.source();source['total']='100'
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):b.write_report(source,Path(tmp))
    def test_requires_capture_time(self):
        source=self.source();del source['captured_at']
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):b.write_report(source,Path(tmp))
    def test_requires_timezone(self):
        source=self.source();source['captured_at']='2026-10-18T12:00:00'
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):b.write_report(source,Path(tmp))
    def test_no_assumed_tax_basis(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp);b.write_report(self.source(),out)
            html=(out/'index.html').read_text()
            self.assertIn('VAT treatment not recorded',html)
            self.assertIn('These amounts do not update',html)
if __name__=='__main__':unittest.main()
