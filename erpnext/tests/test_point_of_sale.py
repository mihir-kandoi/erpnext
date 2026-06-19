# Copyright (c) 2022, Frappe Technologies Pvt. Ltd. and Contributors
# MIT License. See license.txt

import frappe

from erpnext.accounts.doctype.pos_profile.test_pos_profile import make_pos_profile
from erpnext.selling.page.point_of_sale.point_of_sale import get_items, item_group_query
from erpnext.stock.doctype.item.test_item import make_item
from erpnext.stock.doctype.stock_entry.stock_entry_utils import make_stock_entry
from erpnext.tests.utils import ERPNextTestSuite


class TestPointOfSale(ERPNextTestSuite):
	def test_item_group_query_returns_matching_groups(self):
		"""Original raw SQL had no ORDER BY; the get_all conversion injected the doctype default
		`creation desc` on MariaDB (stripped under DISTINCT on Postgres), changing typeahead order on
		MariaDB and making the engines disagree. order_by="" restores the original unordered query on
		both. This covers the previously-untested function and guards the filtered result set."""
		root = (
			frappe.db.get_value("Item Group", {"is_group": 1, "parent_item_group": ""}, "name")
			or "All Item Groups"
		)
		names = [f"_Test POS IG Query {i}" for i in range(3)]
		for n in names:
			if not frappe.db.exists("Item Group", n):
				frappe.get_doc(
					{"doctype": "Item Group", "item_group_name": n, "parent_item_group": root, "is_group": 0}
				).insert(ignore_permissions=True)

		rows = item_group_query("Item Group", "_Test POS IG Query", "name", 0, 20, {})
		got = {r[0] for r in rows}
		for n in names:
			self.assertIn(n, got)

	def test_item_search(self):
		"""
		Test Stock and Service Item Search.
		"""

		pos_profile = make_pos_profile(name="Test POS Profile for Search")
		item1 = make_item("Test Search Stock Item", {"is_stock_item": 1})
		make_stock_entry(
			item_code="Test Search Stock Item",
			qty=10,
			to_warehouse="_Test Warehouse - _TC",
			rate=500,
		)

		result = get_items(
			start=0,
			page_length=20,
			price_list=None,
			item_group=item1.item_group,
			pos_profile=pos_profile.name,
			search_term="Test Search Stock Item",
		)
		filtered_items = result.get("items")

		self.assertEqual(len(filtered_items), 1)
		self.assertEqual(filtered_items[0]["item_code"], item1.item_code)
		self.assertEqual(filtered_items[0]["actual_qty"], 10)

		item2 = make_item("Test Search Service Item", {"is_stock_item": 0})
		result = get_items(
			start=0,
			page_length=20,
			price_list=None,
			item_group=item2.item_group,
			pos_profile=pos_profile.name,
			search_term="Test Search Service Item",
		)
		filtered_items = result.get("items")

		self.assertEqual(len(filtered_items), 1)
		self.assertEqual(filtered_items[0]["item_code"], item2.item_code)
