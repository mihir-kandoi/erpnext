# Copyright (c) 2024, Frappe Technologies Pvt. Ltd. and Contributors
# License: GNU General Public License v3. See license.txt

import frappe
from frappe.utils import today

from erpnext.accounts.doctype.sales_invoice.test_sales_invoice import create_sales_invoice
from erpnext.selling.report.customer_acquisition_and_loyalty.customer_acquisition_and_loyalty import (
	get_customer_stats,
)
from erpnext.tests.utils import ERPNextTestSuite


class TestCustomerAcquisitionAndLoyalty(ERPNextTestSuite):
	def test_same_date_first_seen_classification_is_deterministic(self):
		"""get_customer_stats marks the FIRST invoice seen per customer (in posting_date order) as
		'new' and later ones as 'repeat'. With order_by='posting_date' only, two invoices for the same
		customer on the SAME date in different territories tie, so MariaDB and Postgres can credit 'new'
		to different territories. A name tie-break makes the smaller-named invoice 'new' on both engines.
		(The original SQL ordered by posting_date only, so this hardens a pre-existing non-determinism.)"""
		for terr in ("_Test CAL Terr A", "_Test CAL Terr B"):
			if not frappe.db.exists("Territory", terr):
				frappe.get_doc(
					{
						"doctype": "Territory",
						"territory_name": terr,
						"parent_territory": "All Territories",
						"is_group": 0,
					}
				).insert(ignore_permissions=True)

		cust = "_Test CAL Customer"
		if not frappe.db.exists("Customer", cust):
			frappe.get_doc(
				{
					"doctype": "Customer",
					"customer_name": cust,
					"customer_group": "_Test Customer Group",
					"territory": "_Test CAL Terr A",
				}
			).insert(ignore_permissions=True)

		def mk(terr):
			si = create_sales_invoice(customer=cust, posting_date=today(), do_not_save=1)
			si.territory = terr
			return si.submit()

		si_a = mk("_Test CAL Terr A")
		si_b = mk("_Test CAL Terr B")

		stats = get_customer_stats(
			frappe._dict({"from_date": today(), "to_date": today(), "company": "_Test Company"}),
			tree_view=True,
		)

		# the lexicographically-first invoice name is 'new' on both engines; its territory gets the credit
		first = min(si_a.name, si_b.name)
		new_terr = "_Test CAL Terr A" if first == si_a.name else "_Test CAL Terr B"
		rep_terr = "_Test CAL Terr B" if new_terr == "_Test CAL Terr A" else "_Test CAL Terr A"
		self.assertEqual(stats[new_terr]["new"][0], 1)
		self.assertEqual(stats[new_terr]["repeat"][0], 0)
		self.assertEqual(stats[rep_terr]["repeat"][0], 1)
		self.assertEqual(stats[rep_terr]["new"][0], 0)
