# Copyright (c) 2026, Frappe Technologies Pvt. Ltd. and contributors
# For license information, please see license.txt

import frappe
from frappe.utils import nowdate

from erpnext.accounts.utils import get_fiscal_year
from erpnext.selling.doctype.sales_order.test_sales_order import make_sales_order
from erpnext.selling.report.sales_order_trends.sales_order_trends import execute
from erpnext.tests.utils import ERPNextTestSuite


class TestSalesOrderTrends(ERPNextTestSuite):
	def test_trends_with_group_by_filter(self):
		"""With a Group By filter set, the per-group detail queries reused the multi-column GROUP BY
		string as an equality LHS, producing malformed SQL on both engines; row1 also had bare columns
		with no GROUP BY (Postgres GroupingError). They now use a single-column based-on key and a
		GROUP BY, so the report runs identically on MariaDB and Postgres."""
		so = make_sales_order(transaction_date=nowdate())
		fiscal_year = get_fiscal_year(nowdate())[0]

		filters = frappe._dict(
			{
				"company": so.company,
				"fiscal_year": fiscal_year,
				"period": "Yearly",
				"based_on": "Item",
				"group_by": "Customer",
			}
		)

		# before the fix this raised a SQL syntax / GroupingError; now it returns rows
		columns, data, _message, _chart = execute(filters)
		self.assertTrue(any(so.items[0].item_code in (str(cell) for cell in row) for row in data))
