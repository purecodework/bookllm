from concurrent.futures import ThreadPoolExecutor
import uuid
import pytest
from fastapi.testclient import TestClient
from conftest import create_account
from translation_service.app import create_app
from translation_service.marketplace import Marketplace, Publication
from translation_service.ledger import ServiceError


def book():
    return Publication(publicationID=str(uuid.uuid4()), title='<A & B>', text='Private translated text\n\nChapter 2', targetLanguage='简体中文', styleName='徐志摩', price=10, rightsConfirmed=True)


def test_private_content_and_idempotent_purchase(ledger):
    seller = create_account(ledger, 'seller', amount=0)
    buyer = create_account(ledger, 'buyer')
    other = create_account(ledger, 'other')
    market = Marketplace(ledger); body = book()
    published = market.publish(seller, body)
    assert market.publish(seller, body) == published
    assert 'text' not in market.metadata(published['id'], buyer)
    with pytest.raises(ServiceError) as failure:
        market.content(published['id'], other)
    assert failure.value.status == 403
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: market.purchase(published['id'], buyer), range(20)))
    assert sum(r['charged'] for r in results) == 10
    assert ledger.account(buyer)['points'] == 90 and ledger.account(seller)['points'] == 10
    assert market.content(published['id'], buyer)['text'] == body.text
    assert market.content(published['id'], seller)['text'] == body.text
    with pytest.raises(ServiceError):
        market.purchase(published['id'], seller)
    body.price = 20
    with pytest.raises(ServiceError) as failure:
        market.publish(seller, body)
    assert failure.value.status == 409


def test_no_partial_purchase_and_rights_confirmation(ledger):
    seller = create_account(ledger, 'seller', amount=0)
    buyer = create_account(ledger, 'buyer', amount=0)
    market = Marketplace(ledger); body = book(); body.rightsConfirmed = False
    with pytest.raises(ServiceError): market.publish(seller, body)
    body.rightsConfirmed = True; work = market.publish(seller, body)['id']
    with pytest.raises(ServiceError) as failure: market.purchase(work, buyer)
    assert failure.value.status == 402
    assert ledger.account(seller)['points'] == 0
    assert market.metadata(work, buyer)['purchased'] is False


def test_api_link_escapes_and_hides_content(settings):
    app = create_app(settings)
    seller = create_account(app.state.ledger, 'seller')
    buyer = create_account(app.state.ledger, 'buyer')
    auth = lambda owner: {'Authorization': 'Bearer ' + app.state.sessions.issue(owner)}
    with TestClient(app) as client:
        body = book().model_dump()
        response = client.post('/v1/works', json=body, headers=auth(seller))
        assert response.status_code == 200
        work = response.json()['id']; landing = client.get('/w/' + work)
        assert landing.status_code == 200
        assert '&lt;A &amp; B&gt;' in landing.text and body['text'] not in landing.text
        assert client.get('/v1/works/' + work + '/content', headers=auth(buyer)).status_code == 403
        assert client.get('/v1/works/' + work).status_code == 401
        assert client.post('/v1/works/' + work + '/purchase', headers=auth(buyer)).json()['charged'] == 10
        assert client.get('/v1/works/' + work + '/content', headers=auth(buyer)).json()['text'] == body['text']
        assert client.post('/v1/works/' + work + '/purchase', headers=auth(buyer)).json()['charged'] == 0
        bad = {**body, 'publicationID': str(uuid.uuid4()), 'price': True}
        assert client.post('/v1/works', json=bad, headers=auth(seller)).status_code == 422
        bad = {**body, 'coverBase64': 'bm90LWltYWdl'}
        assert client.post('/v1/works', json=bad, headers=auth(seller)).status_code == 422
        assert client.get('/w/not-a-uuid').status_code == 404


def test_seller_income_reduces_prior_refund_debt(ledger):
    seller = create_account(ledger, 'seller', amount=0)
    buyer = create_account(ledger, 'buyer')
    with ledger.atomic() as db: db.execute('UPDATE accounts SET credit_debt=7 WHERE id=?', (seller,))
    market = Marketplace(ledger); market.purchase(market.publish(seller, book())['id'], buyer)
    assert ledger.account(seller)['creditDebt'] == 0
    assert ledger.account(seller)['points'] == 3
