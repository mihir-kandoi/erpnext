# Copyright (c) 2024, Frappe Technologies Pvt. Ltd. and Contributors
# License: GNU General Public License v3. See license.txt

import frappe

from erpnext.tests.utils import ERPNextTestSuite
from erpnext.www.support.index import get_favorite_articles_by_page_view


class TestSupportIndex(ERPNextTestSuite):
	def test_favorite_articles_group_by_route_not_split(self):
		"""Original report `GROUP BY route` returns one row per route (page-view count summed across
		every published article sharing that route). The conversion groups by name,title,content,
		route,category, which splits a shared route into one row per article -- changing which 6 rows
		survive ORDER BY count DESC LIMIT 6. Both engines agree with the new code but both differ from
		the original MariaDB output."""
		cat = "_Test Audit Category"
		if not frappe.db.exists("Help Category", cat):
			frappe.get_doc({"doctype": "Help Category", "category_name": cat, "published": 1}).insert(
				ignore_permissions=True
			)

		route = "kb/_test-audit-shared-route"
		names = []
		for i in range(2):
			article = frappe.get_doc(
				{
					"doctype": "Help Article",
					"title": f"_Test Audit Guide {i}",
					"category": cat,
					"content": "x",
					"published": 1,
				}
			).insert(ignore_permissions=True)
			# force both published articles onto the SAME route (a realistic title/category collision)
			frappe.db.set_value("Help Article", article.name, "route", route, update_modified=False)
			names.append(article.name)

		for _ in range(5):
			frappe.get_doc({"doctype": "Web Page View", "path": route}).insert(ignore_permissions=True)

		rows = get_favorite_articles_by_page_view()
		route_rows = [r for r in rows if r.get("route") == route]
		# original: exactly ONE row for the shared route; converted: two (one per article)
		self.assertEqual(len(route_rows), 1, f"expected 1 row for shared route, got {route_rows}")
