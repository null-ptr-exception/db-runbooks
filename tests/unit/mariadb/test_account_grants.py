import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[3] / "aqsh-tasks/lib/mariadb-account-grants.py"
SPEC = importlib.util.spec_from_file_location("account_grants", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GrantsTest(unittest.TestCase):
    def verify(self, expected, *actual, supported=""):
        return MODULE.matches(expected, supported, actual)

    def test_implicit_usage_and_reordered_privileges(self):
        expected = [{"scope": "`app\\_db`.*", "privileges": ["SELECT", "INSERT"]}]
        self.assertTrue(self.verify(expected, "GRANT USAGE ON *.* TO 'u'@'%'",
                                    "GRANT INSERT, SELECT ON `app\\_db`.* TO 'u'@'%'"))

    def test_extra_privileges_are_rejected(self):
        expected = [{"scope": "`app`.*", "privileges": ["SELECT"]}]
        self.assertFalse(self.verify(expected, "GRANT SELECT, INSERT ON `app`.* TO 'u'@'%'"))
        self.assertFalse(self.verify(expected, "GRANT SELECT ON `app`.* TO 'u'@'%' WITH GRANT OPTION"))

    def test_case_and_wildcard_scope_are_not_collapsed(self):
        expected = [{"scope": "`App\\_db`.*", "privileges": ["SELECT"]}]
        self.assertFalse(self.verify(expected, "GRANT SELECT ON `app\\_db`.* TO 'u'@'%'"))
        self.assertFalse(self.verify(expected, "GRANT SELECT ON `App_db`.* TO 'u'@'%'"))

    def test_usage_does_not_hide_data_privileges_or_roles(self):
        expected = [{"scope": "*.*", "privileges": ["USAGE"]}]
        self.assertTrue(self.verify(expected, "GRANT USAGE ON *.* TO 'u'@'%'"))
        self.assertFalse(self.verify(expected, "GRANT SELECT ON *.* TO 'u'@'%'"))
        self.assertFalse(self.verify(expected, "GRANT app_role TO 'u'@'%'"))

    def test_explicit_delegation_and_replication_alias(self):
        expected = [{"scope": "*.*", "privileges": ["REPLICATION CLIENT", "GRANT OPTION"]}]
        self.assertTrue(self.verify(expected, "GRANT BINLOG MONITOR ON *.* TO 'u'@'%' WITH GRANT OPTION"))

    def test_all_is_expanded_using_supported_privileges_at_the_same_level(self):
        expected = [{"scope": "`app`.*", "privileges": ["SELECT", "EXECUTE", "TRIGGER", "EVENT"]}]
        supported = "SELECT\tTables\nEXECUTE\tFunctions,Procedures\nTRIGGER\tTables\nEVENT\tServer Admin\nPROCESS\tServer Admin"
        self.assertTrue(self.verify(expected, "GRANT ALL PRIVILEGES ON `app`.* TO 'u'@'%'", supported=supported))
        supported += "\nDELETE\tTables"
        self.assertFalse(self.verify(expected, "GRANT ALL PRIVILEGES ON `app`.* TO 'u'@'%'", supported=supported))

    def test_missing_or_malformed_grants_are_not_zero_privilege_success(self):
        expected = [{"scope": "*.*", "privileges": ["USAGE"]}]
        self.assertFalse(self.verify(expected))
        self.assertFalse(self.verify(expected, "not a grant"))
        self.assertFalse(self.verify(expected, "GRANT SELECT ON `app`.`table` TO 'u'@'%'"))

    def test_recreate_accepts_revocable_direct_grants_at_all_levels(self):
        self.assertTrue(MODULE.recreate_safe([
            "GRANT ALL PRIVILEGES ON *.* TO 'u'@'%' IDENTIFIED BY PASSWORD 'hash' WITH GRANT OPTION",
            "GRANT SELECT ON `app`.* TO 'u'@'%'",
            "GRANT SELECT (`ON`, `TO`) ON `app`.`table` TO 'u'@'%'",
            "GRANT EXECUTE ON PROCEDURE `app`.`proc` TO 'u'@'%'",
        ]))

    def test_recreate_rejects_roles_and_proxy_even_with_quoted_sql_keywords(self):
        for grant in [
            "GRANT app_role TO 'u'@'%'",
            "GRANT `role ON *.* TO fake` TO 'u'@'%' WITH ADMIN OPTION",
            "GRANT `role`` ON *.* TO fake` TO 'u'@'%'",
            'GRANT "role ON *.* TO fake" TO "u"@"%"',
            "GRANT PROXY ON 'other'@'%' TO 'u'@'%' WITH GRANT OPTION",
        ]:
            with self.subTest(grant=grant):
                self.assertFalse(MODULE.recreate_safe([
                    "GRANT USAGE ON *.* TO 'u'@'%'", grant,
                ]))

    def test_recreate_fails_closed_on_missing_or_unrecognized_grants(self):
        for grants in [[], [""], ["not a grant"], ["GRANT missing scope TO 'u'@'%'"]]:
            with self.subTest(grants=grants):
                self.assertFalse(MODULE.recreate_safe(grants))


if __name__ == "__main__":
    unittest.main()
