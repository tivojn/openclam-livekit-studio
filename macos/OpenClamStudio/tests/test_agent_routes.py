import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi import FastAPI

from server.agent_routes import make_router
from tests.test_standalone_openclam import route_test_application


class AgentRouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.studio = route_test_application()
        self.studio.AUTH_TOKEN = 'test-only-local-token'
        app = FastAPI()
        app.middleware('http')(self.studio.security_headers)
        router, self.close = make_router(self.temp.name, Path(__file__).resolve().parents[1] / 'web')
        app.include_router(router)
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://127.0.0.1:9999')
        self.headers = {'x-openclam-token':'test-only-local-token'}

    async def asyncTearDown(self):
        await self.client.aclose()
        await self.close()
        self.temp.cleanup()

    async def test_local_auth_and_same_origin_cover_new_task_routes(self):
        self.assertEqual((await self.client.get('/api/agent/tasks')).status_code,403)
        self.assertEqual((await self.client.post('/api/agent/tasks',headers={**self.headers,'origin':'https://outside.example'},json={})).status_code,403)
        response = await self.client.post('/api/agent/tasks',headers=self.headers,json={})
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.headers['cache-control'],'no-store')
        self.assertTrue(response.json()['task']['cwd'].startswith(str(Path(self.temp.name).resolve())))

    async def test_html_artifacts_download_and_cannot_execute_as_studio(self):
        data=(await self.client.post('/api/agent/tasks',headers=self.headers,json={})).json()
        identity=data['task']['id'];root=Path(data['task']['cwd'])
        (root/'page.html').write_text('<script>parent.alert("unsafe")</script>')
        response=await self.client.get('/api/agent/tasks/'+identity+'/file',params={'path':'page.html'},headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertEqual(response.headers['content-type'],'application/octet-stream')
        self.assertIn('attachment;',response.headers['content-disposition'])
        response=await self.client.get('/api/agent/tasks/'+identity+'/file',params={'path':'../../tasks.sqlite3'},headers=self.headers)
        self.assertEqual(response.status_code,409)

    async def test_assets_are_allowlisted_and_raw_rpc_not_exposed(self):
        self.assertEqual((await self.client.get('/tasks/tasks.js',headers=self.headers)).status_code,200)
        self.assertEqual((await self.client.get('/tasks/config.json',headers=self.headers)).status_code,404)
        self.assertEqual((await self.client.post('/api/agent/rpc',headers=self.headers,json={'method':'process/spawn'})).status_code,404)

    async def test_permission_settings_are_authenticated_validated_and_saved(self):
        created=await self.client.post('/api/agent/tasks',headers=self.headers,json={'permission':'autoReview','model':'gpt-6-astra'})
        task=created.json()['task'];route='/api/agent/tasks/'+task['id']+'/settings'
        self.assertEqual(task['permission'],'autoReview')
        self.assertEqual((await self.client.post(route,json={'permission':'fullAccess'})).status_code,403)
        self.assertEqual((await self.client.post(route,headers={**self.headers,'origin':'https://other.example'},json={'permission':'fullAccess'})).status_code,403)
        self.assertEqual((await self.client.post(route,headers=self.headers,json={'permission':'unknown'})).status_code,409)
        result=await self.client.post(route,headers=self.headers,json={'permission':'fullAccess','model':'gpt-6-astra','effort':'high'})
        self.assertEqual(result.status_code,200)
        self.assertEqual(result.json()['task']['access'],'dangerFullAccess')
        saved=(await self.client.get('/api/agent/tasks/'+task['id'],headers=self.headers)).json()['task']
        self.assertEqual(saved['permission'],'fullAccess')
        self.assertEqual(saved['model'],'gpt-6-astra')
